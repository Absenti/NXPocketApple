// A 16 KB code page in its own __TEXT section, the way nxnative's gen_embed.py places a rewritten module
// (__TEXT,__dm<name>x0). The app finds it with getsectiondata and vm_remaps it elsewhere (copy = FALSE),
// as loader.c does on iOS, then calls it. The code is raw bytes, not a symbol: exactly like a game's code.
    .section __TEXT,__dmx0,regular,pure_instructions
    .p2align 14
    .long 0x52800580        // mov w0, #44
    .long 0xd65f03c0        // ret
    .space 0x4000 - 8
