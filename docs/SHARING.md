# Sharing built games with the iPhone

Today the Mac pushes a package to the iPhone (`devicectl`, cable or Wi-Fi). This adds the other direction: the iPhone app
lists what the Mac has built and downloads the games the player picks, itself. A second source follows, a server reached
over SFTP, where the player picks the folder that holds the built `<title ID>.nxgame` folders.

Both sources end the way a push ends: a folder in `Documents/.incoming/<uuid>/`, a `.complete` marker written last, then
the importer's verify → sign → `rename` (docs/PACKAGE.md). Nothing downstream changes.

## 1. What is at stake

**A package is code.** Its framework is a dylib that the phone signs with the player's certificate and runs with the app's
privileges. The verifier proves a package is consistent with *its own* `package.json`; it cannot prove it is the one the
player's Mac built. So the question for every source is not "can it corrupt the phone" (it cannot, §6) but "who may hand
this phone a package". That is why the Mac's key is pinned and the pairing is mutual, and why an unencrypted transport is not
offered at all (§9).

Everything else is hygiene: no new reachable surface on the phone (it only ever connects out), a Mac that serves one
folder, read-only, to phones the player paired, and nothing at all until the player turns it on, on both devices. The one
thing a paired phone may write on the Mac is a copy of a game's saves (§13), into one folder, as one opaque file.

## 2. Protocol: HTTPS on the local network, with a pinned key

| | |
|---|---|
| Transport | TLS 1.3 only, HTTP/1.1, `GET` and `HEAD` only. |
| Server | the launcher, `NWListener`. macOS has no FTP server (`ftpd` is gone, the only FTP daemon left is the NAT proxy), and the launcher is not sandboxed, so no entitlement is needed. |
| Client | `URLSession` on the phone: a mature HTTP parser is what faces a server that may be hostile; none is hand-written there. |
| Identity | an ECDSA P-256 key the launcher makes once, with a self-signed certificate. The key is a file in `~/Library/Application Support/NXPocketApple/Sharing/` (mode 0600, kept out of backups), not a Keychain item: an ad hoc signed app changes identity at each update and the Keychain would ask the player again, out of context. The identity is built in memory (`SecIdentityCreate`); checked on macOS 27 with a loopback server and a pinned `URLSession`, a wrong pin is refused. |
| Pin | SHA-256 of the **public key**, not of the certificate: renewing the certificate keeps every pairing. The delegate compares it and ignores the system's trust evaluation, so the certificate's names and dates never matter. |
| Authentication | a 256-bit **device token** in `Authorization: Bearer`, issued at pairing. The Mac keeps only its SHA-256, a name and dates. Every failure answers the same `401`. |
| Discovery | Bonjour `_nxpocket._tcp`, plus a typed `host:port` for networks that filter multicast. A forged advertisement gains nothing: it fails the pin. |

Why not the alternatives: **plain HTTP** or **FTP between the two** has neither confidentiality nor server identity, and
the thing travelling is code. **TLS-PSK** would need no certificate, but `URLSession` cannot do it, so an HTTP client would
be hand-written on the phone. **SMB, AirDrop, a cloud folder**: no pairing we control, no resume pinned to a revision.

## 3. Pairing

One pairing window is open at a time (the player pressed **Pair an iPhone…**): two minutes, one phone, three wrong proofs.
Inside it a phone can pair three ways, from the safest to the least convenient: **the QR code** (§3.1), **a number to
compare** (§3.2) and **the typed code** (below). The last is what *Add by address* uses when the first two are not possible.

The Mac shows a one-time code, `123-456` (six digits, about 20 bits), valid 2 minutes, usable once,
burnt after 3 wrong proofs. The player types it on the phone once. The code never goes on the wire; both sides prove they
know it, bound to the key the phone actually saw, so a man in the middle fails in both directions:

```
K        = PBKDF2-HMAC-SHA256(code, salt = "NXPocketApple pairing 1" ‖ pin, 600 000 rounds)
phone →  POST /v1/pair  { device name, nonce, HMAC(K, "c" ‖ pin ‖ nonce ‖ name) }
Mac   →  { token, name, HMAC(K, "s" ‖ pin ‖ nonce ‖ token) }      only if the first proof checks
phone    pins `pin`, keeps token, but only after the Mac's proof checks
```

`pin` is what each side computed from the key *it* used in the handshake. A relay with its own certificate makes the
phone's `pin` differ from the real Mac's, so the real Mac refuses the proof, and the relay cannot fake the Mac's proof
without the code. After pairing the code is worthless.

Six digits are about 20 bits, which is little. What they rest on: three tries and two minutes per code, one use, ten pairing
attempts a minute in all; a code that never goes on the wire (the exchange is inside TLS, so only a relay that is itself
the other end of the handshake ever sees a proof); a derivation made slow on purpose (600 000 rounds, about half a second on
a phone, so a relay that captured one proof cannot try the million codes inside the two minutes); and the key each screen
shows, which the player compares. A longer code would be safer against a relay that has a GPU farm and the player's two
minutes; it is the price of a code that is typed in a breath.

### 3.1 The QR code

The window also has a 128-bit secret, shown as a QR code that carries a link the iPhone's own Camera opens in the app (no
camera permission, no scanner in the app): `nxpocket://pair?h=<address>&p=<port>&k=<pin>&s=<secret>&n=<name>`. The link names
the Mac's key, so the phone does not take a key on trust: it connects, and if the key it sees is not `k`, it stops before it
sends anything (`PairingError.wrongMac`). Then it proves the secret like it would a code, with a key that needs no slow
derivation, since it has 128 bits:

```
K = HKDF-SHA256(secret, salt = pin, info = "NXPocketApple pairing qr 1")
```

and the same `POST /v1/pair` as above: the Mac checks the proof against the code's key and the secret's, and answers with a
proof made with whichever matched. The app only opens a sheet for a link (the Mac's name, its key, one button): nothing is sent
and network sources stay off until the player presses it. A link whose fields are not exactly what they should be (address,
port, a 64-hex key, a 32-hex secret) is ignored. A photo of the QR code is good for the rest of the window only.

### 3.2 Comparing a number

For a Mac whose screen cannot be scanned, or a phone that cannot open the link. The phone cannot choose its number after it
has seen the Mac's, nor the Mac its own after the phone's (a commit and reveal), and each side computes it from the key it
saw in its own handshake, so a relay, which has a different key on each side, cannot make the two screens agree:

```
phone → POST /v1/pair/request  { name, commit = SHA-256(framed(nonceP, name)) }      → { nonce = nonceM }
phone → POST /v1/pair/reveal   { commit, nonce = nonceP }      (the Mac checks the promise; a lie burns the request)
number = first 4 bytes of SHA-256(framed(pin, nonceP, nonceM)) mod 10^6, shown as "482 913" on both screens
phone → POST /v1/pair/confirm  { commit }       sent only after the player pressed "Same" on the phone, then repeated
                                              every second → { state: "waiting" } … { state: "approved", token }
Mac   :  the player presses Allow on the Mac only if the number matches; "Refuse" answers 403.
phone → POST /v1/pair/cancel   { commit }       "Different", or the sheet closed
```

Only while a window is open (otherwise the same `401` as any wrong proof); one request at a time (another phone is told `423`
until the first finishes or the same phone starts over); Allow does nothing before the phone revealed its nonce, so there is
always a number to look at; the token is handed over once, and only when the phone said "Same" *and* the Mac said Allow.
Without a relay, a wrong guess is a one-in-a-million chance; with one, a mismatch the player is shown. A number is weaker than
the QR code against a player who presses Allow without looking, which is why the QR code comes first.

Paired phones are listed in the launcher's Settings (name, paired on, last seen) with **Revoke** (the entry goes and its
open connections are cut at once) and **Reset** (a new key: every phone must pair again). A token unused for 90 days is
dropped. The phone keeps `pin` and token in one Keychain item (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, as the
certificate). When the Keychain refuses (it does under some stores, see `KeychainRefusal`), the pairing is kept for this
run only and the screen says so; **nothing secret is ever written to a file as a fallback.**

## 4. API, version 1

`/v1/games/<TITLEID>/<revision>/files/<path>` is the only path with a variable part. The *revision* is the SHA-256 of that
package's `package.json`, so a download can be tied to one build.

| Request | Answer |
|---|---|
| `GET /v1/hello` (no token) | `{"protocol":1}` |
| `POST /v1/pair` (no token, rate-limited) | §3 |
| `POST /v1/pair/request`, `reveal`, `confirm`, `cancel` (no token, only in a pairing window) | §3.2 |
| `GET /v1/games` | per game: title ID, name, version, `package_version`, `min_os`, revision, bytes (code, RomFS, DLC), modified, `busy` |
| `GET /v1/games/<id>` | `{revision, files:[{path,size}]}`, every entry relative to the package folder |
| `GET /v1/games/<id>/icon` | the icon, a PNG of at most 512 KB, checked on the Mac |
| `GET …/<revision>/files/<path>` | the file; one `Range: bytes=N-` is honoured (`206`), with `ETag`; a revision that is no longer the current one is `409` |
| `PUT /v1/saves/<TITLEID>` (token) | a copy of that game's saves, one `.zip` of 1 byte to 256 MB with a `Content-Length`: §13. `403` when the player turned saves off, `413` too long, `507` no room |

## 5. What the Mac serves, and how it is guaranteed

The shared folder defaults to the *Built games* folder; the player may pick another. A game is listed only if
`LocalLibrary` says it is ready (the phone's shallow check passes).

- **An allow-list built from the package, never a path joined from the request.** For each ready package the server
  builds, from `package.json`, the exact set it will serve: `package.json`, `<framework>/<each listed file>`, `romfs.img`,
  the regular files of `aoc/`, the icon. A request path is percent-decoded once, must pass `SafePath`, and must equal an
  entry of that set; it is a dictionary lookup, so `..`, `%2e%2e`, absolute paths and odd Unicode have nothing to match.
  Anything else, including `prod.keys`, dumps, `save*`, logs, `*.partial`, `_build` folders and hidden files, is `404`.
- **No symlink escape.** Each file is opened with `O_NOFOLLOW`, then the descriptor is checked (`fstat`: a regular file;
  `F_GETPATH`: still under the real shared folder), so there is no gap between the check and the use. A package folder that
  is a link is not a package (the verifier already says so).
- **Read-only.** There is no write verb and no code path that opens a file for writing.
- **Local network only.** TLS 1.3 minimum; no cellular, no peer-to-peer (AirDrop) interface; a peer whose address is not
  loopback, link-local or private (RFC 1918, `fc00::/7`) is dropped before the handshake. A Tailscale address
  (100.64/10) is therefore refused: remote access is out of scope.
- **Caps.** 16 connections in all, 4 per address; 10 s to deliver a request; requests under 2 KB of line and 8 KB of
  headers; keep-alive 60 s; 5 failed tokens from one address in a minute blocks it for a minute (`429`); 10 pairing
  attempts a minute in all.
- **Awake.** While a transfer runs the Mac does not idle-sleep (`ProcessInfo.beginActivity`).
- **Audit.** Pairing, revocation and each finished or failed download go to the launcher's log, with the phone's name.

**While a build runs.** `PackageWriter` builds `<id>.nxgame.partial` and swaps it in with one `replaceItemAt`, so the
folder served is always a whole package, and a file already open keeps the old build until its connection ends. The
listing marks a game `busy` while the queue is building or packing it, and the phone shows "being rebuilt on the Mac" and
does not offer it. A resumed request after the swap carries the old revision and gets `409`; the phone starts that game
again (once, then it says so) rather than splice two builds. Renaming a game rewrites `package.json`, which also changes
the revision: the phone sees "changed on the Mac", not a corrupt file.

## 6. What the iPhone does with what it receives

The phone trusts neither source. A downloaded package goes through the same code as one the Mac pushes, plus checks the
push never needed:

1. **The plan comes from `package.json`, not from the server's listing.** It is fetched first (at most 4 MB,
   `BoundedRead`), decoded with `GamePackage.decode`, and the plan is derived from it: every framework file with its size
   and hash, `romfs.img` with `romfs_size`, `aoc/` files from the listing whose sizes must add up to `aoc_size`. The
   listing must equal the plan; one extra, missing, duplicate, unsafe (`SafePath`), or root-level entry other than
   `package.json`, the framework, `romfs.img` and `aoc` refuses the game before a second byte is fetched. No name from the
   network is ever used as a path unless the plan contains it.
2. **Bounded everything.** Listing ≤ 4 MB and 1 000 games; one game ≤ 200 000 files, ≤ 1 TiB; icon ≤ 512 KB and ≤ 1024 px
   (the header is read, not decoded, before it is shown). A body that exceeds the size asked or listed aborts the request;
   `Content-Range` must match the offset asked; 30 s without a byte is a timeout.
3. **Written only to `Documents/.incoming/<uuid>/`**, through the plan's paths. Small files are hashed as they stream and
   refused on the spot; `romfs.img` is only size-checked (a 15 GB image is never read whole on a phone), the verifier then
   checks its identity at import, as for a push.
4. **`.complete` last, by the phone**, only after every planned file is on disk with exactly its size (and hash). Then the
   existing import does the full verification, the signing and the move. A package refused for being itself wrong
   (a hash, a size, a hostile listing) is deleted; one that failed for the network, the space or the certificate is kept.
5. **Saves are not reachable.** The download never fetches a `save*` entry, and a package whose root holds one is refused
   (new, and it protects the push and Files paths too: `carrySaves` would otherwise leave the player's saves in
   `.replaced-<uuid>` behind a planted `save/`). An update installs through `GameImporter.move`, which carries the old
   `save*` entries over by `rename` as always. A download never writes in `games/`.

## 7. The phone

**Opt-in.** The *Sources* tab starts as one card: what network sources do, and a switch. Until it is on there is no
Bonjour browse, no connection and no Local Network prompt. The card says: "NXPocketApple can look for your Mac on this
network and download the games you pick from it, or from an SFTP server you add. It sends the name you give this iPhone, a
pairing token or a password, and nothing about your games or about you. It does nothing until you turn it on." The update
check keeps its own switch (*Settings → Updates*); `UpdateChannel`'s comment and the `networkNotice` string, which called
it the app's only connection, are corrected.

**Local Network permission.** `NSLocalNetworkUsageDescription` and `NSBonjourServices = [_nxpocket._tcp]` go into
`app/project.yml`. The prompt appears when the player first taps *Find my Mac*, after the screen that explains it. A refusal
is recognised (`NWPath.UnsatisfiedReason.localNetworkDenied`) and answered with the way to Settings and the typed
address.

**Screens.** A fourth tab, *Sources*: your Macs and servers; for one source its games with name, icon, version built,
size, and a state: *not on this iPhone*, *up to date* (same revision as the installed `package.json`), *update available*
(a newer `package_version`, or the revision changed), *older on the Mac*, *needs iOS x*, *being rebuilt*. Several games can
be ticked and run one after another (*Select*, then *Download selected* or *Download all*; a waiting game says where it is in the queue).

**Downloads.** Progress and speed per game, from bytes on disk. **Pause**, **Cancel** (deletes the folder), and resume
after a pause, a drop, a lock or an app kill. A journal in the transfer folder (`.download.json`: source, title ID,
revision, plan, and the offset of `romfs.img` up to which data is known to be on disk) makes that work:

- the journal is rewritten after an `fsync` every 64 MiB; a resume trusts only the journaled offset and truncates the file
  there, so a torn tail after a crash is never mistaken for data;
- a hashed file is re-hashed from disk up to the offset, then continues (a disk reads faster than Wi-Fi);
- **the importer's clean-up of idle transfers stops at a journal**: it deletes a transfer idle for 10 minutes
  (`GameLayout.incomingIdleLimit`), which would destroy a pause. A transfer with a journal is kept 7 days idle, then
  removed to give the gigabytes back;
- the screen stays awake while downloading. Leaving the app asks iOS for the time it grants (`beginBackgroundTask`, about
  thirty seconds): a small game finishes, and when iOS takes the time back (or nothing is left) the running download is paused
  and nothing new starts until the app is in front again, when the paused ones resume. Background `URLSession` is out of scope.

**Updates.** A game a source has in another build than the installed one (`LibraryStatus.updateAvailable`) shows as a tile with
*Update*; *Update all* queues every one. *Update games by themselves* (off by default, in the Sources card) queues them without
asking, each time a source is read, while the app is open and no game is on screen; a download the player paused or
cancelled is not restarted by it. The import carries the saves over as it always did (§6).

**Notifications.** *Tell me when downloads finish* (on by default). When the queue stops while the app is not in front, a local
notification names the games that arrived, says that a download failed, or says that others are waiting. The system's
permission is asked the first time a download starts, so its reason is clear; nothing is registered with any server.

**Space.** Before each game: the bytes still to fetch (listed sizes minus what the journal already holds) plus what the
import keeps aside (`GameImporter.spaceNeeded`: the signed copy of the executable and 1 GiB), against `VolumeSpace`. An
update needs the whole new package on top of the old one, which stays until the `rename`, so the check never subtracts
the installed copy. When it fails the screen says "5.6 GB needed, 3.1 GB free" and nothing is written.

## 8. The Mac

*Settings → Sharing* (a group beside *Sending*):

- **Let paired iPhones download my built games**: off by default, nothing listens. Its detail line says what is shared,
  where, to whom, and that it is read-only and local.
- **Shared folder**: *Same as Built games* until changed.
- When on: the address (`MacBook.local:49217`, port chosen once and kept), a short key fingerprint for the phone to
  show, **Pair an iPhone…** (the QR code, **Cannot scan?** with the typed code, the countdown, and, when a phone asks by number,
  its name and the number with **Refuse** and **Allow**), the paired list with Revoke, **Reset**.
- The first listen triggers macOS's firewall prompt; the README says to allow it.

Stored in `LauncherSettings`: `shareEnabled` (false), `shareFolder` (""), `sharePort` (0 = pick). Settings of earlier
versions decode as before, every field being optional on the way in.

## 9. SFTP

The request said "with a server and an FTP connection where you select the folder with the built folders". It could mean
(a) another source, the phone being the client of a server the player owns, or (b) a server run by the launcher. The
player answered (a) ("a FTP server that holds the built games, which the iPhone fetches from directly") and then
said what they meant by FTP: **SFTP**, the file access NAS boxes and seedboxes offer over SSH. An FTP/FTPS client was
built and tested first, with a fake server; it was replaced rather than kept, because SFTP is what those servers speak
(FTPS needed either a mid-stream TLS upgrade that `Network.framework` cannot do, or TLS session reuse that it cannot ask
for), and an encrypted-by-construction transport leaves no "plain" mode to warn about.

**What is built (`core/…/NXPocketSFTP`).** The iPhone adds a server (host, port, user, and a password or an ed25519 key),
the player picks on the phone **the folder that holds the `<title ID>.nxgame` folders** (a folder browser that starts at
the user's home on the server), and the games found there are listed and downloaded by the same `PackageDownloader` as
the Mac's.

- **A dependency, said plainly.** Apple has no SSH API, and writing an SSH transport (key exchange, ciphers, host-key
  checks) by hand is the kind of code that should not be written once, for one app. The target links
  [Citadel](https://github.com/orlandos-nl/Citadel) 0.9.2 (MIT), pinned exactly, over SwiftNIO SSH (Apache-2.0) and its
  usual companions (NOTICE lists every one). `NXPocketKit` does not link it: it is a separate SwiftPM
  target, `NXPocketSFTP`, which the iPhone app and the Mac launcher (§16) import.
- **The server's key is accepted before anything secret is sent.** `SFTPSource.hostKey(of:)` connects and stops the
  handshake at the host key, so no password and no signature has left the phone; the screen shows `SHA256:…` as
  `ssh-keygen -lf` does, for the player to compare with the server's own tools. The accepted key is pinned (the hash of
  its wire blob): a connection to a server that presents another key is stopped in the handshake, again before any
  secret, and reported with the fingerprint it presented. A server not yet trusted is not connected to at all.
- **Authentication.** A password, or an ed25519 private key in OpenSSH format with its passphrase if it has one. Both
  are kept in the keychain as one item (the same rule as a Mac's token: in memory only if the keychain refuses, never in a
  file). RSA client keys are not offered: they would be signed with SHA-1, which current OpenSSH refuses.
- **Reading only.** The code calls what reads (`realpath`, directory listing, open for reading, `fstat`, `read`, close) and
  nothing that writes, renames or deletes. A package folder is a folder of regular files: a symbolic link, a device or a
  socket anywhere inside is a refusal (the kind comes from the permission bits the server reports and a link is never
  read as what it points to), a name is one path component with no control character, depth ≤ 8, entries ≤ 200 000.
- **Speed.** A request and its answer cost a round trip, which to a seedbox across the internet would cap a one-request-at-
  a-time read at a few megabytes a second. The reader keeps eight 128 KiB reads in flight, hands them out in order, and
  fills a slot again when a server answers with less than it was asked. That window, 1 MiB, is all the stream holds, and
  all a consumer that stops reading leaves outstanding.
- **No revisions.** SFTP has none, so the plan is made from the `package.json` read at the start (its hash is the
  revision) and every file is checked against it as it arrives. A package rebuilt on the server during a download fails
  its hashes and sizes and is removed.
- **Resume.** A read starts at the offset the journal gives (§7). An offset past the end of the server's file is refused.
- **A channel per job.** Each listing or download uses its own SFTP channel on the one SSH connection, closed after it, so
  directory handles a walk opens (the client library never closes them) go with the channel.

**What a server must offer, and what is not supported.** The ciphers are `aes128-gcm@openssh.com` and
`aes256-gcm@openssh.com`, key exchange `curve25519-sha256` or ECDH, host keys `ssh-ed25519` or ECDSA, all of which OpenSSH
has offered since 2014 (every NAS and seedbox running a current OpenSSH or Synology's SSH service does). Not supported: a
server with only an RSA host key or only SHA-1 key exchange (old Dropbear boxes), keyboard-interactive and two-factor
logins, jump hosts, the SSH agent, and servers that offer FTP but not SSH (the NAS needs its SSH or SFTP service on).
When the handshake finds nothing in common the screen says so.

**Accept copies of saves from iPhones** (on with sharing): where the copies go, and the last ten of each game kept. §13.

**What the server can still do.** Hand over a malicious but consistent package (§1). The phone cannot tell; the player
decides whether to trust the server, and a server's key is accepted by name and fingerprint, once.

## 10. What each party can and cannot do

**A hostile Wi-Fi neighbour** (same network, never paired)

- *Can*: see the Mac's Bonjour name, reach the port, start a handshake, call `hello` and `pair`, flood the connection caps
  (the Mac and the phone stay safe; a legitimate transfer may stall), see the volume and timing of a download.
- *Cannot*: list or read any package (every other call is `401`); read anything outside the allow-list; write or delete
  anything; learn the token, the code or the QR secret (TLS 1.3, and none goes on the wire); pair by relaying (proofs bound to the key,
  §3, and a number a relay cannot steer, §3.2); guess the code (six digits, 3 tries, 2 minutes, one use); push anything to the phone (it has no listener).

**A hostile server** (an SFTP server, a man in the middle of its first contact, a Mac whose key leaked)

- *Can*: lie in a listing; stall; send garbage; offer a malicious package that is consistent with itself.
- *Cannot*, enforced on the phone: write outside `.incoming/<uuid>/`; use a name or size the plan does not contain; send
  more bytes than listed; plant `save*`, links or an extra Mach-O (the verifier refuses them); have a partial package
  imported; fill the phone beyond the space check; learn anything but what the player gave it (an SFTP password or key, or the token
  and, to the right key only, which games are asked for).

**A stolen pairing token** (from the phone)

- *Can*: list and download the library from any device on the LAN until it is revoked or 90 idle days pass, while sharing
  is on.
- *Cannot*: be used off the local network (the port drops other addresses); write, delete or reach anything outside the
  allow-list; pair another phone (needs the code); read past traffic. The Mac's file of paired phones holds only token
  hashes, so stealing it authenticates nobody; stealing the Mac's *key file* lets someone pose as the Mac and capture
  tokens, which **Reset** answers.

## 11. Where it is in the code

| | |
|---|---|
| `core/…/Sharing/` | `SharingTypes` (wire types and their bounds), `PackageSource` (the protocol both sources implement), `DownloadPlan` (the plan, derived from `package.json`), `DownloadJournal`, `FileSink`, `PackageDownloader` (resume, space, `.complete`), `LibraryStatus` (installed vs offered), `PairingProof` and `TLSPin`, `LocalNetworkAddress`, `HTTPSession` and `PinnedHTTPSSource` (the Mac client) |
| `core/…/NXPocketSFTP/` | `SFTPSource` and `SFTPReadStream`, `SFTPSession` (the SSH connection, the host-key judge), `SFTPConfig` and `SFTPCredential` |
| `core/…/Package`, `Import` | `PackageVerifier.checkRoot` (§6.5), `GameLayout.downloadJournal` and `pausedDownloadIdleLimit`, the journal rule in `GameImporter.cleanStaleIncoming` |
| `mac/…/NXPMacKit/Sharing/` | `ServerIdentity`, `SharedLibrary` (the allow-list), `HTTPRequest` (the parser), `ShareRouter` with `PairingSessions`, `RateLimiter` and `ConnectionGate`, `ShareServer` (TLS listener), `PairedDevices` |
| `mac/…/NXPMacModel`, `NXPMac` | `AppModel+Sharing`, `SharingSettings` (the Settings group and the pairing sheet), `LauncherSettings.shareEnabled/shareFolder/sharePort` |
| `app/…/NXShellHost`, `NXShellUI` | `SourceStore` (descriptions in preferences, secrets in the keychain), `MacDiscovery` (`NWBrowser`), `NetworkSources` (queue, pause, resume, background), `SourcesScreen` and `SourceSheets`, the strings, `Info.plist` keys (`NSLocalNetworkUsageDescription`, `NSBonjourServices`) and their `InfoPlist.strings` |

`PackageDownloader` and `PinnedHTTPSSource` live in `core/`, and `SFTPSource` beside it, so that the Mac's `swift test` runs the real
client against the real server over TLS on the loopback, a test the simulator could not do. The Mac and HTTPS side added
no dependency (CryptoKit, CommonCrypto for PBKDF2, Security, Network and URLSession are system frameworks); SFTP added the
one of §9, and the repository stays MIT.

**Tests.** In `core/`: the downloader (a whole package, resume after a cut and after a torn tail, a file shorter than its
journal, pause and cancel, another build replacing a waiting one, a rebuild during the download, a body longer than its
file, an endless body, a tampered hash, a wrong offset, ten ways a listing can differ from the plan, space checked before
anything is written, `.complete` only when every file is whole, a link planted where a file goes, saves kept across an
update that came by download), the root allow-list, the importer's seven-day rule, the pairing proofs, address parsing,
the name rule every source shares. In `mac/`: the server and client end to end (right and wrong key, no and wrong token, a wrong, a used and
an expired code, three tries, a relay with another key, revocation, revocation in the middle of a transfer, `409` after
a rebuild, ranges, traversal in every spelling, symbolic links swapped in after the scan, hidden files, a stray `save`),
the parser's refusals, rate limits and caps, the paired phones' file. In `core/`'s `NXPocketSFTPTests`: the SFTP client
against a **real OpenSSH `sshd`**, run as the current user on the loopback with its own host key and one authorised
client key (the host key shown and pinned, another key refused with the fingerprint it showed, nothing sent to a server not
trusted yet, a key the server does not know, an unknown user, an unreadable key, a closed port, browsing, listing, a whole
download over several slots, a read from an offset and past the end, five abandoned reads, a link, an odd name, a path that
leaves the package, a missing game or folder, a tampered file); the tests skip themselves where `sshd` is missing. In
`app/`: the source store (secrets apart from descriptions, a keychain that refuses) and the queue (off by default, a
refused token, pause, cancel, background, a source forgotten).

## 12. Out of scope, and not tried on a device

Out of scope: reaching the Mac over the internet; uploading anything from the phone but a copy of saves; syncing saves in both directions
without being asked; Windows or Linux servers; WebDAV; authenticating a package independently of how it travelled (a signature made by the Mac and
pinned by the phone would make any storage safe; it is a format change).

Everything above runs in tests over real sockets (the HTTPS server and client, the pairing, the allow-list, the journal, and the SFTP client against a
real OpenSSH `sshd`). **Not tried on a phone**: the QR code through the Camera (the number comparison is the way around it); the Local Network prompt and
Bonjour discovery (the typed address is the way around them); whether the keychain keeps a source's secret under FlareStore (the screen says when it
does not); a password sign-in to an SFTP server (the test `sshd` takes keys only) and a Synology, QNAP, seedbox or Dropbear server; a game of several
gigabytes over Wi-Fi, for speed and for the Mac staying awake; a refused Local Network permission on a typed address, which looks like an unreachable Mac.

## 13. Copies of saves, from the phone

The launcher already copies the saves of the games on a cabled phone (`SaveBackup`). This is the other direction, over the
network, and the one write a phone can make.

**What goes.** The game menu's export (`GameSaves.export`): one `.zip` holding the dated folder and `backup.json`. *Saves →
Back up the saves to…* sends one game's; *⋯ → Back up all my saves* on a source sends every game's. Only a source that can keep
them is offered (a Mac, an SFTP server).

**On the Mac**, `PUT /v1/saves/<TITLEID>`, decided from the head of the request alone (`ShareRouter.authorizeUpload`): the
token is checked, then that the title is a game's (`TitleID.isGame`, the folder name is never the phone's text), that the
announced length is 1 byte to 256 MB, that the player left *Accept copies of saves from iPhones* on, and that the volume has
twice the copy and 64 MB free. Only then is the body read, into `.upload-<uuid>` in `<Built games>/Saves/<TITLEID>/`: the first
four bytes must be those of a .zip, no more than the announced length may arrive, thirty seconds of quiet cut it, a phone revoked
in the middle is cut, and a copy that is short is removed. The file is renamed to `iPhone <date>.zip` only when whole, and the
last ten such names stay (a file the player put in the folder is never counted or removed). **The Mac never opens the archive**:
there is nothing in it to extract, so nothing in it can name a path. The parser accepts `PUT` only on that one path shape and
refuses any other (`405`), chunked bodies (`400`) and a missing or oversized length (`411`, `413`).

**On an SFTP server**, the phone writes `<folder>/.nxpocket-saves/<TITLEID>/iPhone <date>.zip`, under a temporary name first and
renamed once whole, and keeps the last ten. The folder is hidden and holds no `package.json`, so the server's listing of games
(`<title ID>.nxgame` folders only) never sees it. The server learns nothing it was not told: the name of the file and its bytes.

**Putting one back.** In the app (`docs/SHARING.md`, *Saves that follow the player*): `GET /v1/saves/<TITLEID>` lists the copies this
Mac holds (`{"copies":[{"name","size"}]}`, only the ones it named itself, newest first) and `GET /v1/saves/<TITLEID>/<name>` gives one,
opened by descriptor with `O_NOFOLLOW` (a name that is not one the Mac made, a link, or anything but a regular file of a sane size is
`404`; `403` while the player has copies switched off, as for the upload). On an SFTP server the phone lists and reads the same hidden folder.
The Mac still never opens an archive. The phone puts a copy back through the import that exists, which checks that it belongs to the game
and is whole. A paired phone can read the copies of every paired phone: they are the same player's.

**Not verified**: a copy of several hundred megabytes over Wi-Fi, a Mac sleeping in the middle, and an SFTP server other than
OpenSSH (the write is tested against OpenSSH only).

## 14. Building a game on the Mac, asked from the phone

The cloud section shows, beside the built games, the games whose dump is in the Mac's own folder and that are not built: a tile
*To build on the Mac*. A touch asks (once, with a question that says it can take an hour); the Mac builds it in its usual queue,
the tile shows *Waiting* and then the progress, and the game downloads by itself when it is among the built ones.

**On the Mac**: *Let paired iPhones start builds of my games*, **on by default** since 2026-11-15 (it was off at first; a setting saved off stays off, and the phone then says so, see `allowed` in the list) (a build is up to an hour of the Mac and gigabytes of
disk). `GET /v1/buildable` lists the dump folder's games with `state` (`idle`, `queued`, `building`, `failed`), `progress` and a bounded
`detail` for a failure, minus the ones already built; with the switch off it lists nothing. `POST /v1/build/<TITLEID>` (token, no
body) is the one request that makes the Mac do work: `403` when the switch is off, `404` when the title is not a game, is already
built or is not in the dump folder, `423` when it is already queued or three are already queued or running for phones. What the
phone sends is a title ID and nothing else; it is looked up in what the launcher already knows (`BuildBoard`), never joined to a path,
and the build is the one the launcher would run for that game with its own choices. Nothing is sent to the phone from the build:
the phone downloads like any other game.

**On the phone** (`NetworkSources`): the list is read with the games, every ten seconds while something builds; a request is
remembered across launches until the game shows up (it is then queued for download) or the build fails (the tile says why). A Mac that
has the switch off answers `403`, and the phone says where to turn it on.

**Not verified**: a real build started from an iPhone; the tests run the server and the client with a stand-in for the queue.

## 15. Differential updates

A package may carry `romfs.blocks` (`docs/PACKAGE.md`): the SHA-256 of each megabyte of the image. When the phone updates a game it
holds, and the new package has the list, `PackageDownloader` does not download the image:

1. it fetches the list (a hashed file like the framework's) and the image is built in `.incoming/<uuid>/` from a **clone** of the
   installed `romfs.img` (`copyItem`, a clone on APFS: no byte is copied, no space is used until a block changes, and the installed
   game is never touched), cut or extended to the new size;
2. it compares every block of the clone with the list, writing nothing;
3. it checks that the blocks that differ fit (the free space must hold them and the headroom), and fetches them, a run of
   neighbours in one request, each block hashed and compared with the list *before* it is written. A block that does not match is a
   package fault (the folder is deleted), as a wrong framework hash is.

The comparison trusts nothing of the clone's earlier state, so a cut connection, a resume, a clone of another size and an image that
had been downloaded whole all take the same path, and a finished image is the list's image or a refusal. The list is as trustworthy as
`package.json`; the importer's checks (size, identity) are unchanged. A game with no installed image, or a package with no list, is
downloaded whole as before.

**What it saves** depends on the game: an update that rebuilds the framework and leaves the RomFS alone costs the framework only (the
image is 15 GB of nothing to fetch). A real patch changes some blocks; an update that **shifts** the content of the image would change
every block after the shift, and fixed blocks cannot see it. That was not measured with a real pair of builds.

**Cost**: the Mac hashes the image once when it packs a game (a read of the image); the phone reads the clone once to compare
(minutes for 15 GB at worst, seconds on a fast flash).

## 16. Putting a built game on the player's own server

The launcher's **Server** tab sets a server up the way the phone does (`ServerSetupFlow`, the same steps as the phone's SFTP sheet): host, port and user,
then a **password or an ed25519 key file**, then the server's host key **shown before anything secret is sent** (the handshake stops at the key, as `ssh`
does) and pinned once the player accepts it, then the folder that holds the games, **chosen by browsing the server** (with *New folder*). The password or
key is one item in the Mac's keychain (`LauncherKeychain`, readable only while the Mac is unlocked, never in the settings or a log); the rest (host, port,
user, pinned key, folder) is in the settings. *Send to my server* in a game's menu then puts the built game there as `<folder>/<title ID>.nxgame`, which is
where an SFTP source on the phone looks (§9), and the tab lists what the server holds. It is what makes the Mac optional once a game is built.

This **links the SFTP client of the phone (Citadel over swift-nio-ssh, §9) into the launcher**; it used to run the system's `sftp`, which cannot take a
password without prompting and cannot browse folders for a screen. The dependency is the one the repository already has, pinned the same way, and
`NXPocketKit` itself still does not link it. `SFTPSource.upload` writes the files: the small ones first, then the image, then `romfs.blocks`, then
`package.json`: **the phone lists a game only when it can read `package.json`, so a game that is not whole is not offered**, and the old `package.json`
of a game being replaced is removed before the first byte of the new one. A file is always sent from its start (a prefix left by an earlier try is not
known to be the same build) and its size is read back from the server before the next one; four writes are in flight at once so the round trip is not
the pace. Links, the Finder's files and the markers of a transfer are not sent. Cancelling stops between two writes and leaves no `package.json`.

Tested against a real `sshd` (the same harness as the phone's source): a game goes up whole and the phone's own downloader takes it back with the same
hash, a second upload replaces the first, a cancel in the middle leaves no game, and the links, the missing `package.json` and the order are checked.
**Not tried**: a password sign-in (the test `sshd` runs as the player and takes keys only), and a NAS that allows SFTP but refuses `mkdir` outside its home or
has another path layout.

## 17. Web libraries

For a library behind an address and nothing else: no Mac on, no FTP, no program on a server. The launcher's *A web copy of my built games* (`WebExport`) writes

```
<folder>/index.json                    {"games":[…]}                  what `GET /v1/games` is
<folder>/<TITLEID>.nxgame/…            the package's files (a clone on the volume of the built games)
<folder>/<TITLEID>.nxgame/files.json   {"revision","files":[{"path","size"}]}   what `GET /v1/games/<id>` is
<folder>/icons/<TITLEID>.png           the icon, a PNG that passes `PNGHeader`
```

from what the sharing server would serve (`SharedLibrary`'s allow-list: the files the package lists, the image, its list of blocks, the add-on content; never a
key, a log, a save or a file the package does not name). A game's folder is replaced whole, and `package.json` is copied last, so a folder cut short does not read
as a game. Put the folder behind https anywhere that answers GET and `Range`.

`WebSource` reads it. The **address is the secret** (a path only the player knows, or a query kept on every request), and an access token may be added, sent as a
bearer token **only to this address**: the address must be https (a plain http link would send the token and the games in the clear), the certificate is judged by
the system (a web server's has a chain, so there is no key to pin as for the Mac), and **no redirect is followed**, so a token cannot be sent anywhere else. The
lists are bounded and compared with the game's own `package.json` as for an SFTP server, every file is checked as it arrives, a path that leaves the package is never
asked, and resuming needs `Range` (a server that answers a range with a whole file is said not to resume). The downloader's resume, the differential update and the
repair work as for any source. Tested with a stand-in for the web server (`URLProtocol`), end to end from the launcher's export to the verifier; **not tried** against
a real host, with a real certificate.


## 18. Downloads that go on while the app is away

A download from the Mac or from a web library goes on when the player is in another app, or when the system has stopped NXPocketApple.
The files of a game are not read by the app's own connection any more but by **the system's background transfer service** (a
`URLSession` with a background configuration, `BackgroundTransfers`), which keeps fetching while the app is suspended or not running.

How it is arranged, so that nothing the downloader checks changes:

- `SegmentedSource` wraps a source that speaks plain HTTPS (`BackgroundReadable`: the Mac and a web server) and answers `read`, the one call
  the downloader makes. A file bigger than 4 MiB is cut at multiples of 32 MiB, each piece a `Range` request of its own, and the next 24
  pieces are always already asked for, so the service has work while the app sleeps. The pieces are read in order and handed to the downloader
  as one stream: its sizes, hashes, journal, block list and resume are as they were. A resume that lands inside a piece reads that piece
  from its start and skips what is already on disk. Small files, and every SFTP download, are read the ordinary way (an SFTP connection
  does not survive the app being suspended).
- A piece is accepted only as exactly the range that was asked for: status 206, a `Content-Range` with the same first byte, last byte and
  file length, and a body of exactly that length (or a whole-file 200 when the piece *is* the whole file). Refusals keep their meaning
  (401, 404, 409 "changed", 423 "busy", 429/503). The same rules as `HTTPSession` hold: the server is the pinned key (Mac) or the system's
  judgement of its certificate (web), no redirect, no proxy, no cookie, no cache, nothing over cellular.
- Everything a task needs to be judged is in the task (its description) and in two small files, because the process that receives the result
  may be a new one: the segment's name is derived from the source, the game, the build and the file, and the way each server is trusted
  is kept in `Application Support/Transfers/trust.json`. A finished piece waits there as `<name>.part` until the downloader reads it;
  a piece that finished while the app was away is found again by name.
- The service wakes the app when it has nothing more to do. `handleEventsForBackgroundURLSession` hands the app what finished; the app
  is kept awake 15 more seconds to read it and ask for the next pieces, then suspended again. Pause and cancel stop the pieces that
  are not finished (a cancel also deletes the ones that are). If the system stopped the app, the downloads that were running (kept in
  the preferences, only for the Mac and web sources) go on at the next start, from the pieces that finished.
- The game is imported when the player next opens the app, as a game from the cable is (signing needs the app in front); a notification
  says the download is done.

What was verified: the decorator and the rules for a piece in the core tests (segments put together are the file, resume inside a piece, the
window, a dropped read stops what it asked for, a wrong-length piece is refused, a whole download through segments is the same package);
and the real service, in the simulator, against a real HTTPS server with `Range` pinned by key (a 96 MB file in 8 MiB pieces has the server's
hash, a wrong key is refused, a finished piece is found again by a new instance). **What was not**: the app actually being suspended or
stopped by the system on an iPhone and woken again, the pace of the wake-ups over a real game, the notification, and a Mac going to sleep
in the middle. Progress moves in steps of one piece (32 MiB) rather than continuously. The player's own force-quit (swiping the app away)
cancels background transfers; that is iOS's rule.

# What the iPhone app keeps for the player

### Offloading a game

*Offload the game* in a game's menu removes the game and keeps everything of the player's: the saves, the settings, the logs and the
play time stay (`GameRemoval` with the saves kept), and the **tile stays in the library** with a cloud and *Offloaded*. A touch
downloads the game again from a source that has it, and the player is back where they were. The icon is copied first into
`Documents/.offloaded/` (the tile has nothing else to draw from); a game no source offers now keeps its tile with "no source has it",
and the question that asks says so before it offloads. A game that comes back by any way (a download, the Mac's cable) is no longer
offloaded. There is no automatic offloading: the player chooses.

### Time Machine of the saves

A copy of a game's saves is taken **when the game is started**, before the session, never while it runs (the game is not writing, so
the copy cannot be torn). It is a Mac copy's layout (`save*` entries and `backup.json`) in `Documents/SaveSnapshots/<title ID>/<date>/`,
an APFS clone, so it costs no space until a save changes. A snapshot identical to the last (names, sizes, dates of the files) is not
taken again; the last 20 stay; saves over 512 MB are not copied at every start. *Saves → Time Machine of the saves* lists them, and a
touch puts those saves back through the import that exists, which keeps the saves it replaces as a copy under `Saves/`. Deleting a
game's saves leaves the snapshots, so an accidental deletion can be undone; erasing everything removes them.

### Play statistics

The game's detail shows the play time, the sessions, and the **average frame rate**. The engine draws in a view of its own and the
app is told nothing of a frame, so the frames are counted where each one passes: a frame asks its `CAMetalLayer` for a drawable, and
`FrameCounter` wraps `nextDrawable` to count the ones that come. Only a count is kept (no frame, pixel or name), once a second, and
only the seconds in which something was drawn count, so a loading screen does not pull the average down; it is shown after ten
seconds of drawing. It is the frame rate when the game draws as often as it is allowed to, which is what the player means by it.
**Not verified on a phone with a real game**: the count assumes the engine's Metal path asks the layer for its drawables, which its
`DM_HUD_PER_LAYER` use of Metal layers suggests but this app has not seen run.

### Certificate reminders

A free account's certificate and profile last seven days, and the first sign of the end is a game that will not start. A local
notification a day and two hours before the earlier of the imported certificate's end and the embedded profile's end says to open
SideStore. It is set from the dates the app reads itself, so it moves by itself when SideStore renews the profile; it asks the
system for permission when first set, nothing is sent anywhere, and *Remind me before it expires* in the certificate card turns it off.

### The TV

The engine's iOS front end already shows a game on a TV (cable or AirPlay): the picture moves to the TV scene and the phone keeps the
pad (`front_ios.m`, `DmTVSceneDelegate`). On iOS 27 it asks for that scene itself; on iOS 26 the app has to offer a scene, which
`ShellAppDelegate` does for the external display role by naming the front end's class. Every other scene is left as SwiftUI makes it.
**Not tried with a TV**: a TV plugged in before a game starts has nothing to show (the class is in the game's framework, loaded at start).

### Checking and repairing a game

*Check and repair the game* reads the whole image and compares each megabyte with `romfs.blocks`, the list that stays installed with the
game (`GameRepair`). A copy cut short through Files, a flash error or a stray write leave an image of the right size that is not the
one built, and the importer's identity check (header and index only) cannot see it. Damaged blocks are fetched again, only those, from a
source whose `package.json` names the **same list** (the same hash), each checked against the list before it is written in place: a
repair that fails leaves the image as bad as it was and never worse, and a source that holds another image of the game is refused.
Only the image is checked: the framework is signed on the phone after the import, so its files no longer have the hashes of
`package.json`, and iOS checks its signature itself. A game installed before the lists existed has nothing to compare with, and the
screen says so. **Not tried** on a real corrupted image or with a game of several gigabytes.

### Going on with another source

A download that fails on the network goes on with another source that offers the same build (the same hash of `package.json`), once for
each: a Mac that falls asleep in the middle of a game is finished from the NAS, from where it stopped (`PackageDownloader`'s
`alsoFrom`). The unfinished folder is taken over, not copied, so the gigabytes are never kept twice. It is done only for packages that
carry the list of blocks, and the image put together from two sources is read whole against the list before the folder is called complete;
a block that does not match is put right from the source that finishes it, and an image that still does not match is a package fault.

### The report of a session

The game's detail draws the last session: the frame rate every thirty seconds, the stretches where the phone was hot shaded behind it,
and the heat and the battery used in a line (`SessionRecorder`, kept in `Documents/settings/<title ID>.session.json`: three numbers per
thirty seconds, the last two hours of the last session, nothing of what was on screen). The heat is iOS's four-level thermal state, the
worst in each bucket, so it says *when* the phone got hot and not how hot. The frame rate has the caveat of *Play statistics* above.

### From the home screen, Siri and Shortcuts

- **A long press on the app's icon** offers the three games played last, newest first, with when (`QuickActions`, `UIApplicationShortcutItem`,
  refreshed after each read of the library and when the app goes to the background). It reaches a scene delegate (`ShellSceneDelegate`),
  at a cold start or while the app runs.
- **Shortcuts**: the action *Play a game* with the game as a parameter (`PlayGameIntent`, an App Intent in the app itself: no extension, so
  no extra App ID for a free account). A shortcut made of it can be added to the home screen from the Shortcuts app, with the icon and name
  the player chooses; the app's own *Add to the home screen* (a profile) stays. The games the intent offers are read from
  `Documents/.catalog.json`, which the model writes at each read of the library, since an intent runs without the model.
- Both leave the request in `GameLaunchInbox`, which the model takes through `request(_:)`: a game already on screen is a question, as for a
  link.
**Not tried on a phone**: the long press and the Shortcuts action (the code is built and its pure parts tested). The scene delegate is
set through the app delegate's scene configuration, the usual way for a SwiftUI app, and a SwiftUI update could change what it does.

### Saves that follow the player

On top of the copies of `docs/SHARING.md` §13, three switches in the Sources card, **all off by default**:

- **Back up my saves by themselves**: after a game was played, the next time the app is in front with no game on screen (so nothing is being
  written), the games whose saves differ from when they were last sent are sent to every source that keeps copies. At most every five
  minutes; a failure is logged and tried again later.
- **Offer newer saves from my other devices**: when a game starts, the sources are asked (four seconds at most) for their copies. The newest,
  if this phone did not send it or dismiss it and it is more than two minutes newer than this phone's last session, is offered: *Use them*
  puts it in place of the saves (these are kept as a copy, as every import does), *Keep mine* does not offer it again. The game starts
  either way. A copy this phone sent is known by the name the destination gave it; saves put back from a copy are marked as sent, so they
  are not sent back as news.
- **Restore** is in *Saves → Time Machine of the saves*: the copies on the Mac and servers are listed under the snapshots, and a touch puts
  one back.

**Conflict**: two devices that played from the same saves each send a copy, and the next to start offers the other's: the player chooses,
and what they replace is kept (Time Machine and `Saves/`). Nothing merges saves. **Not tried** with two real devices.

### Importing a game archive

the library's *plus* button (*Import an archive*) takes a build that comes as one archive, from a file picked in Files (read where it is, never copied
first: a build is gigabytes) or from an **https link** typed in (downloaded to a temporary file that goes as soon as it is unpacked, the
link not kept). It is meant for builds the player made themselves, moved between their own devices, for example from a link only they know.
`GameArchiveImporter` (in the core, tested against the real `zip` and `tar`):

0. **A warning comes first**: the card says in a line that it is only for builds the player made from their own game files, and each import
   (from Files or from a link) asks for a confirmation that explains why: a build holds the game's data and code the app signs and runs, and one
   from anywhere else may be an illegal copy or hold harmful code.
1. **Reads the format by its first bytes**, not its name: `.zip` (with zip64, stored and deflate), `.tar` and `.tar.gz`. **7z, RAR, xz, bzip2
   and zstd are recognised and refused with a message that says so**: 7z needs LZMA and RAR is a proprietary format, neither is in the system,
   and adding a decoder is a decision about a dependency (the licence must stay MIT).
2. **Unpacks into `Documents/.incoming/<uuid>/`**, a megabyte at a time. The archive is a stranger's bytes: a path that leaves the folder, a link,
   a device, an encrypted or unsupported entry, a name a case-insensitive volume would merge with another, a file longer than its header
   says, a checksum that does not match and more files or bytes than a game can have each stop the unpacking, before the byte if it can be
   known (the free space is checked against the zip's own totals before anything is written). The markers of a transfer (`.complete`, …) in an
   archive are never unpacked, so one cannot make a half-unpacked folder look complete.
3. **Finds the build**: at the top of the archive, or inside one or two folders (as Finder and 7-Zip wrap it); none, or several, is refused.
4. **Checks it**: `package.json` is one this app reads, the root holds only what a package holds, the framework is there, the image has its size
   and, when the build carries `romfs.blocks`, **the whole image is read against the list**, so an archive cut short or damaged is found now.
5. **Marks it `.complete` last**, and the import that exists takes it from there: it verifies every file, signs the framework and installs.
   Whatever fails, **the folder it made is removed**: nothing is left of a failed unpacking. The archive the player picked is not touched.

Space: a downloaded archive and what it holds are on the phone at once, so a link needs roughly twice the build's size free (the app says
what is missing before it writes). **Not tried** on a real build of several gigabytes, nor from a real private link.

#### Around the import of an archive

- **The hash.** The launcher's *Export as an archive…* (a game's menu) makes a `.zip` with the system's `zip` (the big files stored, zip64 by itself over 4 GB,
  the Finder's files and the markers of a transfer left out) and shows its **SHA-256**. Given on the iPhone (an optional field in the link
  dialog and in the confirmation), it is checked **before anything is unpacked**: an archive that is not the one the hash names is refused. For a link
  only the player knows, it is what makes sure that the file behind it is still theirs.
- **A folder.** *Choose a folder* imports a build that is already unpacked (on a Mac share Files shows, for instance): copied (a clone on the same
  volume, which costs no space), found, checked and handed over exactly as an archive's is; a link inside it is refused.
- **Open in…, AirDrop.** The app declares `.zip`, `.tar.gz` and `.tar` as documents it can open, **in place** (`LSSupportsOpeningDocumentsInPlace`, so a
  build is not copied first). A build sent by AirDrop from the Mac, or opened from Files with *Open in*, lands on the same warning and confirmation;
  nothing is imported by itself.
- **Resume.** A link download that the network cuts is taken up again where it stopped (the system's resume data, if the server allows ranges), up to
  three times, and the resume data is kept on the phone: the same link given again after the app was closed goes on too. It is forgotten when the
  download ends, and a refused resume starts again from the beginning. The resume file is named from a hash of the link, not the link. **Not tried**
  with a real server that supports ranges.

### Web libraries

A library behind a plain web address: the launcher's *Server* tab → *A web copy of my built games* in the launcher writes a folder (`index.json`, a folder per game
with a `files.json`, the icons) that any web server can serve over https; the iPhone adds its address in *Add a source → Add a web library*. No FTP,
and nothing runs on the server. Details and limits in `docs/SHARING.md` §17. **Not tried** against a real host.

### Cheats

*Cheats* in a game's menu. The engine reads **Atmosphère cheat files** (the `.txt` that cheat sites share, one per version of a game, named after the first
eight bytes of the main module's build ID) and keeps, in files beside them, which cheats are on and a master switch; the app does what a front end does
around that (`Cheats`):

- **The version.** The build writes the main module's build ID into the game (`dm/main.fixups.tsv`); the app reads it, in capitals, as cheat sites name
  files. A game built before that has none, and the screen says to build it again.
- **Import.** A `.txt` picked in Files is **read the way the engine reads it** (`[Name]` and `{Master}`, hex words of 8 digits, no comment syntax, under 64 KiB,
  at most 127 cheats of 256 words) and refused with its line when it would not be, instead of a game that silently ignores it. It is kept in
  `Documents/Cheats/<title ID>/`, **outside the game's folder, which an update or an offload replaces**; the file it replaces is kept as `.bak`. The app
  gives the engine that folder (`DM_CHEATS`).
- **Switches.** Each cheat has a switch, with a search, and a master switch (the engine's own `.cheats-off-<title ID>` file): turning the master off keeps
  the toggles. **A new file starts with nothing on.** What is on is written as the engine reads it (`<build ID>.enabled`, one name per line, a repeated
  name numbered `Name #2`) and is applied **at the next start**.
- **What does not work on an iPhone.** A cheat that writes into the game's code, because the code pages are signed: the engine refuses it and says so in its
  log, whose last `cheats:` lines the screen shows ("what the engine said at the last start"). Cheats that change values in memory (health, items, money)
  are the ones that work. The app does not guess which is which.
- **Safe mode.** The engine turns cheats off after a start that did not come back **on the Mac only**. The app does it itself: a start with cheats on that
  ends with the app dead (the launch guard) turns the master off for that game and says so; the toggles stay.
- **Not covered.** Mods (the engine's single `DM_ROMFS_OVERLAY` folder, never tried with a real mod): not built. **Not tried** with a real cheat file and a
  real game: the grammar and the files are tested, what a cheat does in a game is the engine's.

### Downloads that go on in the background

A download from the Mac or a web library keeps going while you are in another app, or after the system stopped NXPocketApple: the big
files are fetched by the system's own transfer service, in pieces of 32 MiB, and the app is woken when it has pieces to read. SFTP
downloads still pause about thirty seconds after you leave (a notification says so). Pause and cancel work as before. Design, limits
and what was not tried on a phone: `docs/SHARING.md` §18.
