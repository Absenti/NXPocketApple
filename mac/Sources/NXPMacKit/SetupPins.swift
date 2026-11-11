import Foundation

/// What the launcher's first-run setup installs (`FirstRunSetup`), each pinned: a version, and the SHA-256 the
/// download must have before anything of it runs. Moving a pin is a change to this file and its test.
public enum SetupPins {
    public struct Download: Sendable, Equatable {
        public var url: URL
        public var sha256: String
        public var size: Int64
    }

    // MARK: - Python

    /// A Python built to run from any folder (astral-sh/python-build-standalone): no installer, no administrator
    /// password, no Homebrew. 3.14 has `compression.zstd`, which the engine imports.
    public static let pythonVersion = "3.14.10"
    public static let pythonRelease = "20261026"

    public static func python(arm64: Bool) -> Download {
        let triple = arm64 ? "aarch64-apple-darwin" : "x86_64-apple-darwin"
        let name = "cpython-\(pythonVersion)%2B\(pythonRelease)-\(triple)-install_only.tar.gz"
        let url = URL(string: "https://github.com/astral-sh/python-build-standalone/releases/download/\(pythonRelease)/\(name)")!
        return arm64
            ? Download(url: url, sha256: "30a18bcb9ab75e485b4bf4e5d783dde165571e7e42c56dff47a2d2c5345183a4", size: 26_891_793)
            : Download(url: url, sha256: "01cedae5d4a66ac570e13cb35fa570d0e79ba8e9affd4518a5d85b6c2b98ff10", size: 27_054_861)
    }

    /// `tools/python-requirements.txt`, word for word (a test compares them): what `pip install --require-hashes`
    /// installs into the launcher's environment. pip refuses any file whose hash is not listed.
    public static let pythonRequirements = #"""
# The Python packages the engine imports, and theirs, at the versions the launcher installs (FirstRunSetup) and
# tools/setup_python.sh installs: `pip install --require-hashes -r`. Each hash is a macOS wheel or the sdist of that
# release on PyPI. Keep in step with SetupPins.pythonRequirements (a test compares them).
lz4==4.4.5 \
    --hash=sha256:13254bd78fef50105872989a2dc3418ff09aefc7d0765528adc21646a7288294 \
    --hash=sha256:5f0b9e53c1e82e88c10d7c180069363980136b9d7a8306c4dca4f760d60c39f0 \
    --hash=sha256:61d0ee03e6c616f4a8b69987d03d514e8896c8b1b7cc7598ad029e5c6aedfd43 \
    --hash=sha256:67531da3b62f49c939e09d56492baf397175ff39926d0bd5bd2d191ac2bff95f \
    --hash=sha256:6bb05416444fafea170b07181bc70640975ecc2a8c92b3b658c554119519716c \
    --hash=sha256:6d0bf51e7745484d2092b3a51ae6eb58c3bd3ce0300cf2b2c14f76c536d5697a \
    --hash=sha256:7dc1e1e2dbd872f8fae529acd5e4839efd0b141eaa8ae7ce835a9fe80fbad89f \
    --hash=sha256:a1acbbba9edbcbb982bc2cac5e7108f0f553aebac1040fbec67a011a45afa1ba \
    --hash=sha256:b424df1076e40d4e884cfcc4c77d815368b7fb9ebcd7e634f937725cd9a8a72a \
    --hash=sha256:c216b6d5275fc060c6280936bb3bb0e0be6126afb08abccde27eed23dead135f \
    --hash=sha256:c8e71b14938082ebaf78144f3b3917ac715f72d14c076f384a4c062df96f9df6 \
    --hash=sha256:d221fa421b389ab2345640a508db57da36947a437dfe31aeddb8d5c7b646c22d \
    --hash=sha256:d6da84a26b3aa5da13a62e4b89ab36a396e9327de8cd48b436a3467077f8ccd4 \
    --hash=sha256:df5aa4cead2044bab83e0ebae56e0944cc7fcc1505c7787e9e1057d6d549897e \
    --hash=sha256:f6538aaaedd091d6e5abdaa19b99e6e82697d67518f114721b5248709b639fad
capstone==5.0.9 \
    --hash=sha256:0429af292ddc604d3c9344696807e281d5e728db029f00e6a4ea9e3bff1aac9e \
    --hash=sha256:58a874d9a6cb15122135b1385a782e5b54c8a4d9396161b6498465046d2e0442 \
    --hash=sha256:8c4a1d7134d7d5290e5d77066500385f2c7a4bf66835ccbfde5180042d508b3c \
    --hash=sha256:fc269c5082e17d7f9f265cd6980e2fdc6ab572df913951d76db0357e06b8001d
fonttools==4.68.0 \
    --hash=sha256:03c9ef1272e464747f67c623f76449b888da6d5de7fb46275bb36488b9ceedba \
    --hash=sha256:0841a4dac69efda309fca2ed0834186ee66d39787f1d26430ed7f779a699a096 \
    --hash=sha256:362443ab355701d6fd26b10d022cd6c8456e1e248f80103c44cbe5ef0228f87f \
    --hash=sha256:664dfa7a4869b3c827dfc2c38dbbb7a58d53e97933d1bd51ee6729792ee73d50 \
    --hash=sha256:73294e233070f71e2b3653b6bd8564af676d57f26d075761fb06d1ab2e4a7a5d \
    --hash=sha256:86d319a1feedfc75c8ff582d947b21fa1854e2829cb8cf9428784d750a05f1d9 \
    --hash=sha256:93afd51f30ae38f7d826f4632eb799a06bd94e1fb4bc59fdce6d291e93491027 \
    --hash=sha256:956230858b7a7bb9f5e0971ae07dc64b6155307304acd8c62aedca30e6aae874 \
    --hash=sha256:9d80813ae74b969ef2166a3040b591826e80ecd879bdeab7f13f4e8eaf08b345 \
    --hash=sha256:ab6505dfbe3199453d8542b25f55c1ea3260d38029d9db58c0c7304d438abdc0 \
    --hash=sha256:b2ee7b9c1a5e1d637073c39b0978956febad7e862a1269719f527934c65535a4 \
    --hash=sha256:b637d82a488116da2869afbddccfd93ca14e3c47b404c8ec5a9bad9d4381b08c \
    --hash=sha256:d225096687fc3bac0ebe3357e95b2dd8b0a49d191f016db0771d537ccdd6f47e \
    --hash=sha256:d76f8fdcb6936f5e1045a0c9dd721a4bf11112e60d1e243bfa1d39f06a8b3104 \
    --hash=sha256:f15de48b82a816c72f358e772792801bd3788a156caa76e1806cb0aa8148cd61 \
    --hash=sha256:f265c85432c398d86f26add143423924a4747879b2dce001a3ffe0a5fed30638
zbic==1.0.1.post1 \
    --hash=sha256:0032f525191ab247d3f31e1205601ac15c358dd1df0805aab545be79a54779a6 \
    --hash=sha256:0069c42f1350e5f5d2c8f78df8caa72ab25ff2c70628fb63bb9bbfd02bce0183 \
    --hash=sha256:062de16fedfc90928d326282b6053fac751a903824bccf6074637b6795761a74 \
    --hash=sha256:0dcd992b1fecf22ff60018157782505d501b32b512a553387e2b3545982a6910 \
    --hash=sha256:1f199379ad90ed174a7f9c65539f9915cd008b4e6664175f529d7dd1ca03aba5 \
    --hash=sha256:2195fdc7ee7f110237a2d905c33cba15e10393d8d023e6c9e8c93f3929c68546 \
    --hash=sha256:32a2322b2b2337ab95f5878ffb4835f681d91a279e227a276a7bd4eda21ecab4 \
    --hash=sha256:33e5742672a2a2985e1b449fbdb418b972b5ae03a294a758a7ea0321cf6cd1e6 \
    --hash=sha256:3804e92ac57d6a798e9d37a19be884f67e19821c3edbd728ccc5568b50985296 \
    --hash=sha256:3a43ebfdad0eb62ba253ceec2b68a5e9f7fb53087bac01962e4677fb712f470a \
    --hash=sha256:a798c24aea58f81a0b4bb0226f0f383b7e7f07a9a0150732cb45dc65ac541ff3 \
    --hash=sha256:bf9bdfa60aefa9201e5b01c6490c5b2d651ba47f9a5ad240823068a1e22f3ac4 \
    --hash=sha256:db7786f185304e0152dc5e58d262d132ffce4b94d8653add3b2607d79ad7ba7f \
    --hash=sha256:de74b081bc27141ef48fd026f43119cad725937f96b2dd3accff39ae6ae00de9 \
    --hash=sha256:ebffd3ed6d020b71c025660642d208350cff807a302118cf184085c1a78320c5 \
    --hash=sha256:f59bc38b33575832ee0bea450266af273e49fa13a13458672586c7e6b4b39ccc \
    --hash=sha256:f5b9024df8e4d4c62f8071b4397c560857395a168557cbaad2e82faa7b462a7e \
    --hash=sha256:fab1d75bf803f6e3a7890a29afb466c7046f5134d6c3720db86ae162df8c1548 \
    --hash=sha256:fb508131293c71a242b1fc50e9179da2a73a4ec42dfcf3652963672bbe144e12
nsz==5.0.0 \
    --hash=sha256:b3698cab8d7720aed056a0290017ff60a989d8343b7bb9c3c161ab137ec03965 \
    --hash=sha256:dcada02e80f06721a64c4d7dbd7d74ae569cdb6502be634f4ea16ffb06fa89eb
pycryptodome==4.2.0 \
    --hash=sha256:21d7fdba239d6ef863d3d08388801c683453a3bb4897c2b27f27847aad89bdf7 \
    --hash=sha256:30f418cd1f4e776bde6c5df1fcd90ddfe74dfc8f679286a82f17ec1d4018cce0 \
    --hash=sha256:3e430168f767ecec60c1f850df4abbd0b9f94786b9cc8041a00e976f6d5190c6 \
    --hash=sha256:42ab554efcc14928f1db42deac9c84989fd49e289a16aacbbee709fe2eb838cc \
    --hash=sha256:4b58c4fd5615a788e0df6793d578e565b19d75a348c0ba02d469b0c38bbf0332 \
    --hash=sha256:7ea7dbf6b8ce0f0d2c0e17c1226c74d07c01499db7704797bdbb6cb9ec511ccb \
    --hash=sha256:aea22120791b4534a27e39fc01d91265a249ba72dbd682a8a5c1adee475d5483
zstandard==0.25.0 \
    --hash=sha256:05df5136bc5a011f33cd25bc9f506e7426c0c9b3f9954f056831ce68f3b6689f \
    --hash=sha256:4b14abacf83dfb5c25eb4e4a79520de9e7e205f72c9ee7702f91233ae57d33a2 \
    --hash=sha256:4d441506e9b372386a5271c64125f72d5df6d2a8e8a2a45a0ae09b03cb781ef7 \
    --hash=sha256:7713e1179d162cf5c7906da876ec2ccb9c3a9dcbdffef0cc7f70c3667a205f0b \
    --hash=sha256:7b3c3a3ab9daa3eed242d6ecceead93aebbb8f5f84318d82cee643e019c4b73b \
    --hash=sha256:913cbd31a400febff93b564a23e17c3ed2d56c064006f54efec210d586171c00 \
    --hash=sha256:933b65d7680ea337180733cf9e87293cc5500cc0eb3fc8769f4d3c88d724ec5c \
    --hash=sha256:a1a4ae2dec3993a32247995bdfe367fc3266da832d82f8438c8570f989753de1 \
    --hash=sha256:a3f79487c687b1fc69f19e487cd949bf3aae653d181dfb5fde3bf6d18894706f \
    --hash=sha256:b9af1fe743828123e12b41dd8091eca1074d0c1569cc42e6e1eee98027f2bbd0 \
    --hash=sha256:e29f0cf06974c899b2c188ef7f783607dbef36da4c242eb6c82dcd8b512855e3 \
    --hash=sha256:e59fdc271772f6686e01e1b3b74537259800f57e24280be3f29c8a0deb1904dd \
    --hash=sha256:ec996f12524f88e151c339688c3897194821d7f03081ab35d31d1e12ec975e94
enlighten==1.14.1 \
    --hash=sha256:5fbd0c959ca1644034c41bb0ace5db19c9852cf9d721b6103f5f130663c57be8 \
    --hash=sha256:85c35412a9a4f3886b3337d41f813441fab9a30d9f5b5f0c015bd078a4411473
blessed==1.52.0 \
    --hash=sha256:1936f421f3feb130035a4629e6477d1432e33b2674ab2b9841292c74d479eac2 \
    --hash=sha256:a6f42b2875c7afee78420ac9919699d5c3dce35bfa9ad45bc158b1713fc33d0d
jinxed==2.1.0 \
    --hash=sha256:43b802d18b70e405d410fb66eb2837d1101e7e5ea922e666507bb43f34d11d09 \
    --hash=sha256:7e755b831faa2443d44fb4ce7c0202eb9c3ed39bd5bf1193365888f4f6092b54
prefixed==0.9.0 \
    --hash=sha256:164403fa9ebc83280bbc4705f4b243a28837e164310b4e65c38ccab1ebafeeb3 \
    --hash=sha256:3cdb74bfc4cf0aba28f3574662b13afdcac27c463dcbef320fe5d03f4c5fbca8
wcwidth==0.9.4 \
    --hash=sha256:87e4101789415a6cf55ec4c53eceeb4782c2654c88692941cb588f19dca1959f \
    --hash=sha256:901eace6d2dd25ebb917d0ce5db18e5c537e1504c905cf32f0d006c12098b05d \
    --hash=sha256:a8c9ce14c6b4a499e61de6de7e9e456de11be8bc991554e2ab2ed4feb40b9664 \
    --hash=sha256:ab1e5190fb82476e75fbf963e9d59b4fb1c1e1f4ced82069a0c989016aa959f7 \
    --hash=sha256:b7969c9aa258d536df54c8ac8af5cad0c74a6268c9972e1fb60a5f29feffb66d \
    --hash=sha256:d68f09093c9bec9226a52edc47487042ed4f64c5df91d06f00419495071c0279 \
    --hash=sha256:f279f32c8e206a9092fa350e53ca0c2bd8072e45b1c9fd31bb6d476b59b591c4 \
    --hash=sha256:fd8d57d3cdfe570e3265c8fab1885c24e34ef40889c0759c0c304a19e9835954
backports.zstd==1.8.0 ; python_version < "3.14" \
    --hash=sha256:045e15ed3b3ebd8816edaa7d66f024becf050d9aec09605f549ce33cfda01098 \
    --hash=sha256:1eae18c682f7daf8d7b39c988516d7a123ec446beb77f709d0cb1475ab57f0cc \
    --hash=sha256:2b11fb8b9c798657c97ad3165893f146c300e2f7f800e9c54c0d2143052c1486 \
    --hash=sha256:403985e468f1cccb87a7e9e4f1d78106ea8e77dcdda3038d645d052a8d8e1ce3 \
    --hash=sha256:49c4006cdf41c15ffcc74f10d9a6485be841106cd4d5aa7ea7bf1075cc37fb83 \
    --hash=sha256:4c4af1b9542bc6420d55ff47d7efe13c19f56a80cbdd1ffd0a29767801dab886 \
    --hash=sha256:4fa862d24b7fb392279a95bc9acc1f0ede8a25de9efbed03fb305ceac2f6abb0 \
    --hash=sha256:5173afe530ca59bba8938a19edcb875c70f78bf9fee01cb3614a97876d112962 \
    --hash=sha256:6e024aee6bfd04094fce60133b0e6bd0f8027cdb2823157880bc87f1ffdfee21 \
    --hash=sha256:8efdb220f34418cef987da10d857cf95cdcffe431cc0e536efc25d7279abf118 \
    --hash=sha256:900b357bbae805bb98672471ede748c80ccfc1212be0b4ef52a102750ef742a7 \
    --hash=sha256:9dae4f4c481716e3db473d667457b4f508ff7459c0931b567a5c9677fb3db316 \
    --hash=sha256:d810d83c8a703f424ed2a49aa271078c91b530da2d8c104bd88207e68d116de8 \
    --hash=sha256:e213317db53e787ef7bf13c5a2070bd98a888ca7603bbd1904ede443c197f3cc \
    --hash=sha256:f710d03f84d74f11737735f846b44ef1545cadb73ef47bcd3d0e124f253dd763
"""#

    // MARK: - XcodeGen

    /// Only the iPhone app's build and the memory helper need it.
    public static let xcodegenVersion = "2.46.0"
    public static let xcodegen = Download(
        url: URL(string: "https://github.com/yonaskolb/XcodeGen/releases/download/2.46.0/xcodegen.zip")!,
        sha256: "4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806", size: 4_278_764)

    // MARK: - The engine

    public static let nx2appleRepository = "https://github.com/LNPANDY/NX2Apple.git"
    /// The NX2Apple commit whose `tools/engine.py sync` gives the engine this project's builds were made with: nxnative
    /// at f25fa956 plus NX2Apple's 63 patches.
    public static let nx2appleRevision = "36131205c6a216494bade764398ae22d43165fbc"
    /// The `key` line `engine.py sync` writes into `engine/.git/nx2apple-stamp` for that commit: the digest of the pin
    /// and of every patch. An engine tree with another key is not the pinned one.
    public static let engineKey = "c65b42ce7e503dbd864ff731bbc568d3d288ee41b586bd9aaccc99115476063d"
}
