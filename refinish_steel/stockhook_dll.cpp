// stockhook_dll.cpp
// =====================================================================
// STOCKHOOK: module-defined stockpile entries for Dwarf Fortress
// DLL, layout 6 (1: test 3; 2: part rows; 3: material aliases; 4: larger
// tables; 5: the category colour hook, 2026-11-02; 6: the automatic
// target, 2026-11-09)
// =====================================================================
// WHAT: a standalone DLL that DF loads through its dfhooks chain-loader
// (any dfhooks_<name>.dll in DF's folder, or a dfhooks_<name>.ini there
// pointing at one). It detours DF's master stockpile check, "does this
// pile's settings accept this item", and answers for items a mod has
// CLAIMED, by rules the mod defined. Every other item goes to DF's own
// function untouched, so vanilla stockpiling cannot break.
//
// HOW IT TALKS TO LUA: the DLL owns one fixed block of memory (THE BLOCK,
// below) and publishes its address in the environment variable
// STOCKHOOK_BLOCK. stockhook.lua finds it there and writes the tables
// straight into it: claims, entries, piles. The DLL only reads them, plus
// a few counters it writes back for Lua to show. Nothing is passed by file.
//
// THE TARGET (RM_Notes/RM_Stockpile_Filing_Disassembly.md):
//   DF 53.16 Steam, RVA 0x55E920,
//   bool settings_accepts(stockpile_settings*, item*, int32_t* out, bool r9)
//   On accept DF returns (1 - r9); on every reject it returns 0. *out is
//   set to 0 on entry. The hook mirrors both exactly when it answers.
//   Tests 1 and 2 (2026-11-01): hooked cleanly, all calls on the game
//   thread, and answering yes here makes dwarves haul and bin an item DF
//   would never file (Making Fuel's coal on a Coal-only pile).
//
// NO DFHACK DEPENDENCY: does not link against dfhack.dll, so a DFHack
// update can never break it. Finds its target by byte pattern and refuses
// to hook if the pattern is missing or ambiguous.
//
// DF UPDATES (THE TARGETS and THE AUTOMATIC TARGET, below): besides the
// target function, the hook calls four of the item's virtual methods by
// vtable offset, and an update can move those without touching the
// function. So bytes alone never decide. A build is hooked when either:
//   * it is LISTED: built in, or a line in stockhook_targets.txt beside the
//     DLL (the mod ships it; the installer copies it). A listed build is
//     taken as written; or
//   * it is VERIFIED (layout 6, 2026-11-09): for a build not listed, the
//     DLL checks at launch everything a person checked by hand for 53.17
//     (the reference signatures found exactly once, the stolen bytes
//     unchanged, the item vtable read through DF's own RTTI, the check
//     still calling the material slots), and hooks only if every check
//     passes. Each check and its result goes to stockhook.log, with a
//     ready-made targets line for the build.
// A build that is neither is left alone, cleanly, and RM's own fallback
// runs; RM's prompt says so at the fort load (refinish-stockhook-install.lua,
// THE FALLBACK PROMPT).
// WHY VERIFIED BUILDS ARE SAFE TO HOOK: DF 53.17 moved both functions and
// changed nothing the hook relies on, which is the usual shape of a DF
// patch. The checks prove the same facts the hand check proved. What they
// cannot prove is a change deeper inside DF's function (what it returns
// on accept, say) behind an unchanged start; the hand check could not
// either, and in-play hauling stays the final word.
//
// THE SECOND TARGET, THE CATEGORY COLOUR (layout 5, 2026-11-02): DF
// colours each category of the stockpile settings screen (red, grey,
// green) from its own entries only, by
//   int8_t list_state(stockpile_settings*, stockpile_list)   RVA 0x55A6D0
// which returns 0 when none of the list's entries is on, 1 when some are
// and 2 when all are (read from its tail: r14b "any on", sil "any off",
// 0 if none on, else 1 + all on). The settings screen's renderer calls it
// for every category (RVA 0x37E230, 82 calls), its input handler to
// decide what a click does (RVA 0x311C10), and the pile's name builder
// (RVA 0x55E010). A Stockhook row is not a DF entry, so a category holding
// only Stockhook rows read red. The colour hook asks DF, then folds in the
// list's Stockhook rows for this pile (THE COLOUR ROWS): any on makes it
// at least grey, any off keeps it from green. Optional: a build line
// without it hooks the stockpile check alone.
//
// SAFETY:
//   * the 19 bytes overwritten are checked byte for byte first;
//   * a file named stockhook.disable in DF's folder stops it;
//   * while the block's 'enabled' word is 0 the hook decides nothing;
//   * the original bytes go back at shutdown.
//
// THREADS: tests 1 and 2 saw every call on the game thread, and DFHack's
// Lua runs on the game thread too, so the block is never read and written
// at once. If a later test shows calls elsewhere, writes must be staged.
//
// BUILD (x64 Native Tools Command Prompt for VS 2022, in this folder):
//   cl /nologo /O2 /EHsc /MD /LD stockhook_dll.cpp /Fe:dfhooks_stockhook.dll
// INSTALL: copy dfhooks_stockhook.dll into DF's folder (beside the exe).
//   Delete dfhooks_rmstock.dll (the test 1/2 build) first: two hooks on
//   one function would chain, and only one may decide.
// =====================================================================

#include <windows.h>
#include <intrin.h>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdarg>
#include <cstddef>

#pragma intrinsic(_ReturnAddress)

// =====================================================================
// THE TARGETS: one per DF build
// =====================================================================
// A target is everything the hook assumes about one DF build:
//   build    the exe's PE timestamp (FileHeader.TimeDateStamp), which
//            names the build
//   rva      where the function is expected; it is also found by a scan of
//            .text for the signature, exactly once, if it moved
//   stolen   how many bytes of the function's start the jump replaces:
//            whole, position independent instructions only, at least
//            JMP_LEN, at most MAX_SIG
//   vt       the vtable byte offsets of the item's getType, getSubtype,
//            getMaterial and getMaterialIndex (df-structures' order; DF's
//            own stockpile code calls +0x00, +0x10 and +0x18 in 53.16)
//   sig      the function's first bytes; ?? in the file matches any byte,
//            but never inside the stolen bytes, which are copied as found
//   crva, cstolen, csig   the same three for the colour function (THE
//            SECOND TARGET, above); optional. A line for a known build that
//            leaves them out keeps the built-in colour target of that build.
//
// The 53.16 Steam build is built in. stockhook_targets.txt in DF's folder
// adds builds, one per line, and a line for a build already known replaces
// it:
//   build 6A70A6D9 rva 55E920 stolen 19 vt 0 8 10 18 sig 40 56 41 54 ...
//     crva 55A6D0 cstolen F csig 48 89 5C 24 08 ...
// Numbers are hex. Everything after # is a comment.
// A build neither built in nor listed gets THE AUTOMATIC TARGET (below).
static const size_t JMP_LEN = 14;
static const size_t MAX_SIG = 96;

struct Target {
    uint32_t build;
    uint32_t rva;
    size_t   stolen;
    size_t   vt[4];          // getType, getSubtype, getMaterial, getMaterialIndex
    uint8_t  sig[MAX_SIG];
    uint8_t  mask[MAX_SIG];  // 1: this byte must match; 0: ?? (any)
    size_t   siglen;
    // ---- THE COLOUR FUNCTION (optional) ----
    bool     has_colour;
    uint32_t crva;
    size_t   cstolen;
    uint8_t  csig[MAX_SIG];
    uint8_t  cmask[MAX_SIG];
    size_t   csiglen;
    // ---- THE AUTOMATIC TARGET (layout 6) ----
    // true: not listed; built from the reference signatures and hooked only
    // once verify_automatic() passes. No known RVA: both are found by scan.
    bool     automatic;
};

// DF 53.16 Steam (PE timestamp 0x6A70A6D9), RVA 0x55E920: the function's
// first 32 bytes, unique in that exe; its first 19 are push rsi, push r12,
// push r13, push r14, sub rsp 28h and mov dword [r8], 0.
// Also THE REFERENCE for the automatic target: DF 53.17 (0x6AEA05A1) has
// the same 32 bytes at RVA 0x577E00 (read from the exe, 2026-11-09).
static const uint8_t SIG_5316[32] = {
    0x40, 0x56, 0x41, 0x54, 0x41, 0x55, 0x41, 0x56,
    0x48, 0x83, 0xEC, 0x28, 0x41, 0xC7, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x48, 0x8B, 0xF1, 0x48, 0x8B,
    0x02, 0x48, 0x8B, 0xCA, 0x45, 0x0F, 0xB6, 0xE9
};

// DF 53.16 Steam, RVA 0x55A6D0, the colour function: its first 81 bytes
// (unique in that exe), the stack cookie's address (bytes 42 to 45) left as
// ?? since it is rip-relative. The first 15 are three movs saving rbx, rsi
// and rdi to the shadow space, and the last three are cmp edx, 6Ch: the
// stockpile_list switch (a ja to the default follows, so lists 0 to 108),
// so a DF that adds a list fails the signature instead of being misread.
// The automatic target leaves that last byte as ?? and checks the list
// count against DFHack's instead (THE LIST COUNT, below). DF 53.17 has the
// same 81 bytes at RVA 0x573BB0.
static const uint8_t CSIG_5316[81] = {
    0x48, 0x89, 0x5C, 0x24, 0x08, 0x48, 0x89, 0x74, 0x24, 0x10, 0x48, 0x89,
    0x7C, 0x24, 0x18, 0x55, 0x41, 0x54, 0x41, 0x55, 0x41, 0x56, 0x41, 0x57,
    0x48, 0x8D, 0xAC, 0x24, 0x70, 0xFF, 0xFF, 0xFF, 0x48, 0x81, 0xEC, 0x90,
    0x01, 0x00, 0x00, 0x48, 0x8B, 0x05, 0x00, 0x00, 0x00, 0x00, 0x48, 0x33,
    0xC4, 0x48, 0x89, 0x85, 0x88, 0x00, 0x00, 0x00, 0x48, 0x8B, 0xF9, 0x33,
    0xDB, 0x44, 0x8B, 0xE3, 0x89, 0x5C, 0x24, 0x40, 0x89, 0x5C, 0x24, 0x44,
    0x45, 0x32, 0xF6, 0x40, 0x32, 0xF6, 0x83, 0xFA, 0x6C
};
static const size_t CSIG_LIST_BYTE = 80;   // the 6Ch of cmp edx, 6Ch

// The target this run uses (find_target), and its vtable offsets, read by
// the hook on every call.
static Target g_tgt = {};
static size_t VT_GET_TYPE      = 0x00;  // int16 item_type
static size_t VT_GET_SUBTYPE   = 0x08;  // int16 itemdef subtype
static size_t VT_GET_MAT_TYPE  = 0x10;  // int16 mat_type
static size_t VT_GET_MAT_INDEX = 0x18;  // int32 mat_index

// =====================================================================
// THE BLOCK: the shared tables, laid out byte for byte
// =====================================================================
// stockhook.lua writes these at the SAME offsets (its OFF table). Change
// one side, change the other, and raise LAYOUT so a mismatch refuses
// rather than misreads.
static const uint32_t LAYOUT = 6;   // 2: EF_PART, CF_EXACT_INDEX; 3: material aliases; 4: larger tables; 5: colour rows (2026-11-02); 6: automatic target, list count (2026-11-09)

// Layout 4 (2026-11-02): room for generated rows (every tool kind as a type,
// every tree as a material in each list with a Wood entry): 4096 entries,
// 4096 module bits per pile, 32768 claims. About 2.8 MB, static.
static const int MAX_CLAIMS  = 32768;
static const int MAX_ENTRIES = 4096;
static const int MAX_PILES   = 2048;
static const int PILE_BYTES  = 512;   // 4096 module entry bits per pile
static const int ALIAS_SLOTS = 4096;  // material alias hash table (power of 2)
static const int MAX_COLOUR  = 8192;  // colour rows (layout 5)
static const int N_LISTS     = 128;   // stockpile_list values covered

#pragma pack(push, 1)

// A claim: items matching it are this DLL's to answer, by one entry.
// -1 in subtype, mat_type or mat_index means "any", except that a claim
// with CF_EXACT_INDEX matches mat_index -1 only: DF's refined coal is
// builtin COAL with mat_index -1, beside coke (0) and charcoal (1), and has
// to be claimable on its own (layout 2).
enum : int32_t { CF_EXACT_INDEX = 0x01 };
struct Claim {
    int16_t  item_type;    // 0
    int16_t  subtype;      // 2
    int16_t  mat_type;     // 4
    uint16_t entry;        // 6   index into entries[]
    int32_t  mat_index;    // 8
    int32_t  flags;        // 12  CF_*
};                         // 16 bytes

// An entry: how a pile's settings decide for the items claimed under it.
enum : uint8_t { KIND_NONE = 0, KIND_FOLLOW = 1, KIND_MODULE = 2, KIND_NEVER = 3 };
// FOLLOW: a byte of DF's own settings decides (e.g. bars_other_mats[Coal]).
// MODULE: a bit RM keeps per pile decides (a mod's own row).
// NEVER:  no pile takes it (keys that must never be hauled).
enum : uint8_t { EF_ALSO_VANILLA = 0x01, EF_PART = 0x02, EF_VANILLA_ITEM = 0x04 };
// ALSO_VANILLA: when the entry says no, DF's own answer is asked as well.
// PART: a MODULE entry that is a part of a vanilla entry (Coke and Charcoal
//   of Coal). In a pile Lua listed, its bit decides, with no group needed.
//   Anywhere else (a hauling route stop's settings), the vanilla entry's
//   byte decides, as it would without Stockhook: vec_offset / vec_index
//   name that byte and group_mask that entry's group.
// VANILLA_ITEM (with PART): the part covers items DF itself files under the
//   vanilla entry (oak beds under Beds, coke under Coal, a tool kind under
//   Tools). Its row decides only whether the pile wants that part; the
//   rest of the pile's settings (materials, quality, and so on) still
//   apply, by asking DF's own check with the vanilla entry's byte set to 1
//   for that one call (test 17: an oak bed part took oak beds that the
//   pile's material and quality settings refused).

struct Entry {
    uint8_t  kind;         // 0
    uint8_t  flags;        // 1
    uint16_t bit;          // 2   MODULE: which per-pile bit
    uint32_t group_mask;   // 4   the pile's group flag that must be on
                           //     (PART: the vanilla entry's group)
    uint32_t vec_offset;   // 8   FOLLOW, PART: vector's offset in stockpile_settings
    uint32_t vec_index;    // 12  FOLLOW, PART: which byte of that vector
};                         // 16 bytes

// A pile: its settings' address (as DF passes it to the check) and its
// module entry bits. The address is only ever compared, never followed.
struct Pile {
    uint64_t settings;           // 0
    uint8_t  bits[PILE_BYTES];   // 8     a module row's value
    uint8_t  set[PILE_BYTES];    // 520   PART rows: 1 when the player set
                                 //       this part in this pile; 0 when it
                                 //       still follows its vanilla entry
};                               // 1032 bytes

// ---- MATERIAL ALIASES (layout 3) ----
// A material that files as another: a hidden twin (Making Fuel's fuel wood
// twin of oak, RM's stone twins) as its source (oak WOOD). For the length of
// one stockpile check the item is given the source material, so claims and
// DF's own check both see oak; the item's own fields are put back before
// the hook returns. Lua fills an open-addressing hash of from -> to pairs
// and, per item type, where the item keeps its material (the offsets of
// mat_type and mat_index in that item class; 0 means unknown, no alias).
struct AliasSlot {
    int16_t  from_mt;      // 0
    int16_t  to_mt;        // 2
    int32_t  from_mi;      // 4
    int32_t  to_mi;        // 8
    uint32_t used;         // 12  1 when the slot holds a pair
};                         // 16 bytes
struct MatOff {
    uint16_t mat_type;     // 0   offset of the int16 mat_type field
    uint16_t mat_index;    // 2   offset of the int32 mat_index field
};                         // 4 bytes

// ---- THE COLOUR ROWS (layout 5) ----
// One per Stockhook row shown in a settings list: which list it sits in,
// its group, and where its value is. ENTRY: a module or part entry's value
// in the pile (part_value, pile bit). BYTE: a byte of the pile's own
// settings (a moved material's row, shown in another list than DF's).
enum : uint8_t { CR_ENTRY = 0, CR_BYTE = 1 };
struct ColourRow {
    uint8_t  list;         // 0   stockpile_list value it is shown in
    uint8_t  kind;         // 1   CR_*
    uint16_t entry;        // 2   CR_ENTRY: index into entries[]
    uint32_t group_mask;   // 4   its group's flag
    uint32_t vec_offset;   // 8   CR_BYTE: vector's offset in stockpile_settings
    uint32_t vec_index;    // 12  CR_BYTE: which byte
};                         // 16 bytes

struct Block {
    // ---- HEADER, offset 0, 64 bytes ----
    char     magic[8];     // 0    "STKHOOK1"
    uint32_t layout;       // 8    LAYOUT
    uint32_t enabled;      // 12   Lua: 1 when the tables below are valid
    uint32_t n_claims;     // 16
    uint32_t n_entries;    // 20
    uint32_t n_piles;      // 24
    uint32_t hooked;       // 28   DLL: 1 when the detour is in place
    int64_t  calls;        // 32   DLL: every call
    int64_t  yes;          // 40   DLL: this DLL answered yes
    int64_t  no;           // 48   DLL: this DLL answered no
    int64_t  passed;       // 56   DLL: handed to DF's own function
    // ---- CLAIMS BY ITEM TYPE, offset 64 ----
    // claims[] is sorted by item type; a type's claims are
    // type_start[t] .. type_start[t] + type_count[t] - 1, most specific
    // first (the first match wins).
    uint32_t type_start[256];    // 64
    uint32_t type_count[256];    // 1088
    // ---- TABLES ----
    Claim    claims[MAX_CLAIMS];   // 2112
    Entry    entries[MAX_ENTRIES]; // 526400
    Pile     piles[MAX_PILES];     // 591936
    // ---- MATERIAL ALIASES, layout 3 ----
    MatOff    mat_off[256];        // 2705472  per item type
    uint32_t  n_alias;             // 2706496  pairs in the table (0: skip)
    uint32_t  alias_pad[3];        // 2706500
    AliasSlot aliases[ALIAS_SLOTS];// 2706512
    // ---- THE COLOUR ROWS, layout 5 ----
    // list_info[list]: that list's group flag; bit 31 set when the list is
    // a whole group (Food, Furniture ...), whose colour takes every row of
    // the group.
    uint32_t  list_info[N_LISTS];  // 2772048
    uint32_t  n_colour;            // 2772560
    uint32_t  colour_hooked;       // 2772564  DLL: 1 when the colour hook is in place
    int64_t   colour_calls;        // 2772568  DLL: every call
    ColourRow colour[MAX_COLOUR];  // 2772576
    // ---- THE AUTOMATIC TARGET AND THE LIST COUNT, layout 6 ----
    // Appended, so every offset above is unchanged.
    uint32_t  automatic;           // 2903648  DLL: 1 when hooked as a verified, unlisted build
    uint32_t  list_max;            // 2903652  DLL: the highest stockpile_list DF's colour
                                   //          function switches on (THE LIST COUNT); 0: unread
    uint32_t  colour_ok;           // 2903656  Lua: 1 when DFHack's stockpile_list covers list_max;
                                   //          the colour hook folds nothing while 0
    uint32_t  auto_pad;            // 2903660
};                                 // 2903664 bytes

#pragma pack(pop)

static_assert(sizeof(Claim) == 16, "Claim layout");
static_assert(sizeof(Entry) == 16, "Entry layout");
static_assert(sizeof(Pile) == 1032, "Pile layout");
static_assert(offsetof(Block, type_start) == 64, "Block layout");
static_assert(offsetof(Block, claims) == 2112, "Block layout");
static_assert(offsetof(Block, entries) == 526400, "Block layout");
static_assert(offsetof(Block, piles) == 591936, "Block layout");
static_assert(sizeof(AliasSlot) == 16, "AliasSlot layout");
static_assert(offsetof(Block, mat_off) == 2705472, "Block layout");
static_assert(offsetof(Block, n_alias) == 2706496, "Block layout");
static_assert(offsetof(Block, aliases) == 2706512, "Block layout");
static_assert(sizeof(ColourRow) == 16, "ColourRow layout");
static_assert(offsetof(Block, list_info) == 2772048, "Block layout");
static_assert(offsetof(Block, n_colour) == 2772560, "Block layout");
static_assert(offsetof(Block, colour) == 2772576, "Block layout");
static_assert(offsetof(Block, automatic) == 2903648, "Block layout");
static_assert(offsetof(Block, list_max) == 2903652, "Block layout");
static_assert(offsetof(Block, colour_ok) == 2903656, "Block layout");
static_assert(sizeof(Block) == 2903664, "Block layout");

static Block g_block;   // zeroed at load: enabled = 0 until Lua fills it

// =====================================================================
// STATE
// =====================================================================
typedef bool (*accept_fn)(void* settings, void* item, int32_t* out, uint8_t r9);
static accept_fn g_original = nullptr;

static uintptr_t g_base = 0;
static uint8_t*  g_target = nullptr;
static uint8_t   g_saved[MAX_SIG];    // the stolen bytes, put back at shutdown
static bool      g_hooked = false;

// ---- THE COLOUR HOOK ----
typedef int8_t (*state_fn)(void* settings, int32_t list);
static state_fn  g_colour_original = nullptr;
static uint8_t*  g_ctarget = nullptr;
static uint8_t   g_csaved[MAX_SIG];
static bool      g_chooked = false;
static FILE*     g_log = nullptr;

// =====================================================================
// READING DF'S DATA
// =====================================================================
typedef int16_t (*vf_i16)(void*);
typedef int32_t (*vf_i32)(void*);
static inline void* vslot(void* obj, size_t off) {
    uintptr_t vt = *(uintptr_t*)obj;
    return *(void**)(vt + off);
}

// One byte of a std::vector<char> (begin at +0, end at +8); past its end
// counts as 0, as DF's own code treats it.
static inline uint8_t vec_byte(const uint8_t* vec, size_t idx) {
    const uint8_t* b = *(const uint8_t* const*)(vec);
    const uint8_t* e = *(const uint8_t* const*)(vec + 8);
    if (!b || idx >= (size_t)(e - b)) return 0;
    return b[idx];
}

// A pile's module bit, looked up by the settings address DF passed:
// 1 or 0, or -1 for a settings block that is not a pile Lua listed (a
// hauling route stop, say). Callers treat -1 as off, except PART entries.
static inline int pile_bit(const void* settings, uint16_t bit) {
    uint64_t key = (uint64_t)(uintptr_t)settings;
    uint32_t n = g_block.n_piles;
    if (n > (uint32_t)MAX_PILES) n = MAX_PILES;
    for (uint32_t i = 0; i < n; i++) {
        if (g_block.piles[i].settings == key)
            return (g_block.piles[i].bits[bit >> 3] >> (bit & 7)) & 1;
    }
    return -1;
}


// A PART row's value in a pile: 1 or 0, or -1 for settings that are not a
// listed pile. A part the player never set in this pile FOLLOWS its vanilla
// entry live (its byte in the pile's settings), so a pile keeps no stored
// value for the hundreds of generated parts it never touched, and a part
// added later starts at the vanilla entry's value with nothing written.
static inline int part_value(const void* settings, const Entry& e) {
    if (e.bit >= PILE_BYTES * 8) return 0;
    uint64_t key = (uint64_t)(uintptr_t)settings;
    uint32_t n = g_block.n_piles;
    if (n > (uint32_t)MAX_PILES) n = MAX_PILES;
    for (uint32_t i = 0; i < n; i++) {
        const Pile& p = g_block.piles[i];
        if (p.settings == key) {
            uint16_t b = e.bit;
            if ((p.set[b >> 3] >> (b & 7)) & 1) return (p.bits[b >> 3] >> (b & 7)) & 1;
            return vec_byte((const uint8_t*)settings + e.vec_offset, e.vec_index) != 0;
        }
    }
    return -1;
}

// =====================================================================
// THE COLOUR HOOK
// =====================================================================
// The listed pile whose settings these are, or -1.
static inline int pile_index(const void* settings) {
    uint64_t key = (uint64_t)(uintptr_t)settings;
    uint32_t n = g_block.n_piles;
    if (n > (uint32_t)MAX_PILES) n = MAX_PILES;
    for (uint32_t i = 0; i < n; i++) if (g_block.piles[i].settings == key) return (int)i;
    return -1;
}

// A colour row's value in pile p: 1 or 0. A part the player never set
// follows its vanilla entry, as part_value reads it.
static inline int colour_value(const void* settings, const Pile& p, const ColourRow& r) {
    if (r.kind == CR_BYTE) return vec_byte((const uint8_t*)settings + r.vec_offset, r.vec_index) != 0;
    if (r.entry >= g_block.n_entries || r.entry >= MAX_ENTRIES) return 0;
    const Entry& e = g_block.entries[r.entry];
    uint16_t b = e.bit;
    if (b >= PILE_BYTES * 8) return 0;
    int v = (p.bits[b >> 3] >> (b & 7)) & 1;
    if ((e.flags & EF_PART) && !((p.set[b >> 3] >> (b & 7)) & 1))
        v = vec_byte((const uint8_t*)settings + e.vec_offset, e.vec_index) != 0;
    return v;
}

// DF's answer (0 none on, 1 some, 2 all), with the list's Stockhook rows
// in this pile folded in. A list (or group) with none of our rows, and any
// settings that are not a listed pile, keep DF's answer exactly. So does
// everything while Lua has not confirmed the list count (colour_ok, THE
// LIST COUNT): DF's numbering of lists and DFHack's must agree for
// list_info and the rows' lists to mean anything.
static int8_t colour_hook(void* settings, int32_t list) {
    int8_t r = g_colour_original(settings, list);
    g_block.colour_calls++;
    if (!g_block.enabled || !g_block.colour_ok || !settings || list < 0 || list >= N_LISTS) return r;
    uint32_t n = g_block.n_colour;
    if (n > (uint32_t)MAX_COLOUR) n = MAX_COLOUR;
    if (!n) return r;
    int pi = pile_index(settings);
    if (pi < 0) return r;
    const Pile& p = g_block.piles[pi];
    uint32_t info = g_block.list_info[list];
    bool whole_group = (info & 0x80000000u) != 0;
    uint32_t gm = info & 0x7FFFFFFFu;
    bool on = false, off = false;
    for (uint32_t i = 0; i < n && !(on && off); i++) {
        const ColourRow& c = g_block.colour[i];
        bool mine = whole_group ? (gm && (c.group_mask & gm)) : (c.list == (uint32_t)list);
        if (!mine) continue;
        if (colour_value(settings, p, c)) on = true; else off = true;
    }
    if (!on && !off) return r;
    // DF's 0 is "none of its entries on"; with ours on the list is mixed.
    bool any_on = (r != 0) || on;
    bool any_off = (r != 2) || off;
    if (!any_on) return 0;
    return any_off ? 1 : 2;
}

// =====================================================================
// THE HOOK
// =====================================================================
// Pass straight to DF's function.
static inline bool pass(void* s, void* it, int32_t* out, uint8_t r9) {
    g_block.passed++;
    return g_original(s, it, out, r9);
}

// The slot an alias for (mt, mi) would sit in, the same hash Lua fills
// (stockhook.lua, alias_hash).
static inline uint32_t alias_hash(int16_t mt, int32_t mi) {
    return (((uint32_t)(uint16_t)mt * 2654435761u) ^ ((uint32_t)mi * 40503u)) & (ALIAS_SLOTS - 1);
}

static bool decide(void* settings, void* item, int32_t* out, uint8_t r9);

static bool hook(void* settings, void* item, int32_t* out, uint8_t r9) {
    g_block.calls++;
    if (!g_block.enabled || !item || !settings) return pass(settings, item, out, r9);

    // ---- MATERIAL ALIAS ----
    // Only when Lua listed aliases and knows where this item type keeps its
    // material. The item's fields are rewritten for this call and put back.
    if (g_block.n_alias) {
        int16_t it = ((vf_i16)vslot(item, VT_GET_TYPE))(item);
        if (it >= 0 && it < 256) {
            const MatOff& mo = g_block.mat_off[it];
            if (mo.mat_type && mo.mat_index) {
                int16_t mt = ((vf_i16)vslot(item, VT_GET_MAT_TYPE))(item);
                int32_t mi = ((vf_i32)vslot(item, VT_GET_MAT_INDEX))(item);
                uint32_t h = alias_hash(mt, mi);
                for (int n = 0; n < ALIAS_SLOTS; n++, h = (h + 1) & (ALIAS_SLOTS - 1)) {
                    const AliasSlot& a = g_block.aliases[h];
                    if (!a.used) break;
                    if (a.from_mt == mt && a.from_mi == mi) {
                        int16_t* pmt = (int16_t*)((uint8_t*)item + mo.mat_type);
                        int32_t* pmi = (int32_t*)((uint8_t*)item + mo.mat_index);
                        // Only if the fields really hold the material the
                        // getters returned: a wrong offset is never written.
                        if (*pmt != mt || *pmi != mi) break;
                        *pmt = a.to_mt; *pmi = a.to_mi;
                        bool r = decide(settings, item, out, r9);
                        *pmt = mt; *pmi = mi;
                        return r;
                    }
                }
            }
        }
    }
    return decide(settings, item, out, r9);
}

// Everything below asks the item for its material through its getters, so
// an aliased item reads as its source throughout.
static bool decide(void* settings, void* item, int32_t* out, uint8_t r9) {

    // ---- CLAIMED TYPE? ----
    // One virtual call rules out every item type no claim names.
    int16_t it = ((vf_i16)vslot(item, VT_GET_TYPE))(item);
    if (it < 0 || it >= 256 || g_block.type_count[it] == 0) return pass(settings, item, out, r9);
    uint32_t start = g_block.type_start[it];
    uint32_t count = g_block.type_count[it];
    if (start + count > g_block.n_claims || start + count > (uint32_t)MAX_CLAIMS)
        return pass(settings, item, out, r9);

    // ---- THE FIRST CLAIM THAT MATCHES ----
    int16_t st = ((vf_i16)vslot(item, VT_GET_SUBTYPE))(item);
    int16_t mt = ((vf_i16)vslot(item, VT_GET_MAT_TYPE))(item);
    int32_t mi = ((vf_i32)vslot(item, VT_GET_MAT_INDEX))(item);
    auto matches = [&](const Claim& c) {
        return (c.subtype == -1 || c.subtype == st) &&
               (c.mat_type == -1 || c.mat_type == mt) &&
               (c.mat_index == mi || (c.mat_index == -1 && !(c.flags & CF_EXACT_INDEX)));
    };
    int entry = -1;
    uint32_t first_i = 0;
    for (uint32_t i = start; i < start + count; i++) {
        if (matches(g_block.claims[i])) { entry = g_block.claims[i].entry; first_i = i; break; }
    }
    if (entry < 0 || (uint32_t)entry >= g_block.n_entries || entry >= MAX_ENTRIES)
        return pass(settings, item, out, r9);

    // ---- PARTS ON EVERY AXIS (VANILLA_ITEM) ----
    // When the most specific claim is a VANILLA_ITEM part, EVERY matching
    // VANILLA_ITEM part decides together, through ONE call to DF's own
    // check in which each part's vanilla entry byte is set to the part's
    // own row (1 on, 0 off), then put back:
    //   * two axes of one group AND: an oak kindling under "Kindling" (a part
    //     of Tools) and "Oak" (a part of Wood), both in Finished goods, is
    //     taken only if both rows are on;
    //   * separate groups OR, as DF's own check does: an oak tool with
    //     Finished goods' "Oak" off but Furniture's "Oak" on can still be
    //     filed as furniture, and with Furniture's Wood on but its "Oak" off
    //     it cannot slip in through Furniture's Wood;
    //   * every other setting of the pile (quality, other lists) applies.
    // Claims that are not VANILLA_ITEM parts are not part of this; a pile
    // that is not listed (a route stop) is DF's alone, as without Stockhook.
    {
        const Entry& e0 = g_block.entries[entry];
        if ((e0.flags & EF_PART) && (e0.flags & EF_VANILLA_ITEM)) {
            const int MAXP = 16;
            int parts[MAXP]; int np = 0;
            for (uint32_t i = first_i; i < start + count && np < MAXP; i++) {
                const Claim& c = g_block.claims[i];
                if (!matches(c) || c.entry >= g_block.n_entries || c.entry >= MAX_ENTRIES) continue;
                const Entry& e = g_block.entries[c.entry];
                if (!((e.flags & EF_PART) && (e.flags & EF_VANILLA_ITEM))) continue;
                bool seen = false;
                for (int k = 0; k < np; k++) if (parts[k] == c.entry) seen = true;
                if (!seen) parts[np++] = c.entry;
            }
            // Each part's own row. -1 (not a listed pile): DF alone.
            uint8_t want[MAXP];
            for (int k = 0; k < np; k++) {
                int b = part_value(settings, g_block.entries[parts[k]]);
                if (b < 0) return pass(settings, item, out, r9);
                want[k] = (uint8_t)b;
            }
            // Each vanilla entry byte set to its part's row, DF asked, every
            // byte put back. A vector too short to hold its byte is left as
            // it is (DF reads past its end as 0, so that entry is off).
            uint8_t* where[MAXP]; uint8_t was[MAXP]; int nw = 0;
            for (int k = 0; k < np; k++) {
                const Entry& e = g_block.entries[parts[k]];
                uint8_t* vec = (uint8_t*)settings + e.vec_offset;
                uint8_t* bgn = *(uint8_t**)(vec);
                uint8_t* end = *(uint8_t**)(vec + 8);
                if (!bgn || e.vec_index >= (uint32_t)(end - bgn)) continue;
                uint8_t* w = bgn + e.vec_index;
                bool dup = false;   // two parts of one entry: on if either is
                for (int q = 0; q < nw; q++) if (where[q] == w) { dup = true; if (want[k]) *w = 1; }
                if (dup) continue;
                where[nw] = w; was[nw] = *w; *w = want[k]; nw++;
            }
            bool r = g_original(settings, item, out, r9);
            for (int k = nw - 1; k >= 0; k--) *where[k] = was[k];
            if (r == (r9 ? false : true)) g_block.yes++; else g_block.no++;
            return r;
        }
    }

    // ---- THE ENTRY DECIDES ----
    const Entry& e = g_block.entries[entry];
    uint32_t flags = *(const uint32_t*)settings;   // stockpile_settings.flags
    // A group_mask of 0 means the entry needs no group switched on. That is
    // how module rows are defined: in DF's settings screen a group is on
    // only while one of its vanilla entries is, so a pile holding nothing
    // but a module row has its group off (measured, test 3, 2026-11-01).
    bool group_on = e.group_mask == 0 || (flags & e.group_mask) != 0;
    bool yes = false;
    switch (e.kind) {
    case KIND_FOLLOW:
        yes = group_on && vec_byte((const uint8_t*)settings + e.vec_offset, e.vec_index) != 0;
        break;
    case KIND_MODULE: {
        int b = (e.flags & EF_PART) ? part_value(settings, e)
              : (e.bit < PILE_BYTES * 8 ? pile_bit(settings, e.bit) : 0);
        if (e.flags & EF_PART) {
            // Listed pile: the part's own bit, no group needed. Elsewhere:
            // the vanilla entry, exactly as a FOLLOW entry reads it.
            if (b >= 0) yes = b == 1;
            else yes = group_on && vec_byte((const uint8_t*)settings + e.vec_offset, e.vec_index) != 0;
        } else {
            yes = group_on && b == 1;
        }
        break;
    }
    case KIND_NEVER:
        yes = false;
        break;
    default:
        return pass(settings, item, out, r9);
    }
    if (!yes && (e.flags & EF_ALSO_VANILLA)) return pass(settings, item, out, r9);

    // Mirror DF's contract: *out starts at 0; accept returns (1 - r9),
    // reject returns 0.
    if (out) *out = 0;
    if (yes) { g_block.yes++; return r9 ? false : true; }
    g_block.no++;
    return false;
}

// =====================================================================
// LOGGING
// =====================================================================
static void log_line(const char* fmt, ...) {
    if (!g_log) return;
    va_list ap;
    va_start(ap, fmt);
    vfprintf(g_log, fmt, ap);
    va_end(ap);
    fputc('\n', g_log);
    fflush(g_log);
}

// =====================================================================
// FINDING AND PATCHING
// =====================================================================
// ---- THE BUILT-IN TARGET ----
static Target builtin_5316() {
    Target t = {};
    t.build = 0x6A70A6D9;
    t.rva = 0x55E920;
    t.stolen = 19;
    t.vt[0] = 0x00; t.vt[1] = 0x08; t.vt[2] = 0x10; t.vt[3] = 0x18;
    memcpy(t.sig, SIG_5316, sizeof SIG_5316);
    memset(t.mask, 1, sizeof SIG_5316);
    t.siglen = sizeof SIG_5316;
    t.has_colour = true;
    t.crva = 0x55A6D0;
    t.cstolen = 15;
    memcpy(t.csig, CSIG_5316, sizeof CSIG_5316);
    memset(t.cmask, 1, sizeof CSIG_5316);
    for (int i = 42; i <= 45; i++) t.cmask[i] = 0;   // the stack cookie's address
    t.csiglen = sizeof CSIG_5316;
    return t;
}

// ---- stockhook_targets.txt ----
// One target from one line, or false (and why, logged) for a line that is
// not one. Tokens: build, rva, stolen, vt (four numbers), sig (the rest).
static bool parse_target(char* line, Target& t, int lineno) {
    t = {};
    char* save = nullptr;
    bool have_build = false, have_rva = false, have_stolen = false, have_vt = false;
    bool have_crva = false, have_cstolen = false;
    // A token that starts another field ends a byte list (sig, csig).
    auto is_key = [](const char* v) {
        return !strcmp(v, "build") || !strcmp(v, "rva") || !strcmp(v, "stolen") || !strcmp(v, "vt")
            || !strcmp(v, "sig") || !strcmp(v, "crva") || !strcmp(v, "cstolen") || !strcmp(v, "csig");
    };
    char* pending = nullptr;   // a key read while reading bytes, handled next
    for (char* tok = strtok_s(line, " \t\r\n", &save); tok || pending;
         tok = pending ? nullptr : strtok_s(nullptr, " \t\r\n", &save)) {
        if (pending) { tok = pending; pending = nullptr; }
        if (!strcmp(tok, "build")) {
            char* v = strtok_s(nullptr, " \t\r\n", &save);
            if (!v) break;
            t.build = (uint32_t)strtoul(v, nullptr, 16); have_build = true;
        } else if (!strcmp(tok, "rva")) {
            char* v = strtok_s(nullptr, " \t\r\n", &save);
            if (!v) break;
            t.rva = (uint32_t)strtoul(v, nullptr, 16); have_rva = true;
        } else if (!strcmp(tok, "stolen")) {
            char* v = strtok_s(nullptr, " \t\r\n", &save);
            if (!v) break;
            t.stolen = (size_t)strtoul(v, nullptr, 16); have_stolen = true;
        } else if (!strcmp(tok, "vt")) {
            int n = 0;
            for (; n < 4; n++) {
                char* v = strtok_s(nullptr, " \t\r\n", &save);
                if (!v) break;
                t.vt[n] = (size_t)strtoul(v, nullptr, 16);
            }
            have_vt = (n == 4);
        } else if (!strcmp(tok, "sig")) {
            for (char* v = strtok_s(nullptr, " \t\r\n", &save); v;
                 v = strtok_s(nullptr, " \t\r\n", &save)) {
                if (is_key(v)) { pending = v; break; }
                if (t.siglen >= MAX_SIG) continue;
                if (!strcmp(v, "??")) { t.sig[t.siglen] = 0; t.mask[t.siglen] = 0; }
                else { t.sig[t.siglen] = (uint8_t)strtoul(v, nullptr, 16); t.mask[t.siglen] = 1; }
                t.siglen++;
            }
        } else if (!strcmp(tok, "crva")) {
            char* v = strtok_s(nullptr, " \t\r\n", &save);
            if (!v) break;
            t.crva = (uint32_t)strtoul(v, nullptr, 16); have_crva = true;
        } else if (!strcmp(tok, "cstolen")) {
            char* v = strtok_s(nullptr, " \t\r\n", &save);
            if (!v) break;
            t.cstolen = (size_t)strtoul(v, nullptr, 16); have_cstolen = true;
        } else if (!strcmp(tok, "csig")) {
            for (char* v = strtok_s(nullptr, " \t\r\n", &save); v;
                 v = strtok_s(nullptr, " \t\r\n", &save)) {
                if (is_key(v)) { pending = v; break; }
                if (t.csiglen >= MAX_SIG) continue;
                if (!strcmp(v, "??")) { t.csig[t.csiglen] = 0; t.cmask[t.csiglen] = 0; }
                else { t.csig[t.csiglen] = (uint8_t)strtoul(v, nullptr, 16); t.cmask[t.csiglen] = 1; }
                t.csiglen++;
            }
        }
    }
    // ---- THE COLOUR TARGET: all three, or none ----
    if (have_crva || have_cstolen || t.csiglen) {
        bool ok = have_crva && have_cstolen && t.csiglen
            && t.cstolen >= JMP_LEN && t.cstolen <= t.csiglen;
        for (size_t i = 0; ok && i < t.cstolen; i++) if (!t.cmask[i]) ok = false;
        if (ok) t.has_colour = true;
        else log_line("targets file, line %d: crva, cstolen and csig incomplete or bad;"
            " the colour hook is skipped for this line.", lineno);
    }
    if (!(have_build && have_rva && have_stolen && have_vt && t.siglen)) {
        log_line("targets file, line %d: needs build, rva, stolen, vt (4 numbers) and sig; ignored.", lineno);
        return false;
    }
    if (t.stolen < JMP_LEN || t.stolen > t.siglen) {
        log_line("targets file, line %d: stolen %zu must be at least %zu and within the signature; ignored.",
            lineno, t.stolen, JMP_LEN);
        return false;
    }
    for (size_t i = 0; i < t.stolen; i++) {
        if (!t.mask[i]) {
            log_line("targets file, line %d: ?? inside the stolen bytes; ignored.", lineno);
            return false;
        }
    }
    return true;
}

// The target for this exe's build: a line of stockhook_targets.txt for it,
// else the built-in one if it is this build. false when the build is not
// listed: then THE AUTOMATIC TARGET decides.
static bool pick_target(uint32_t build, Target& out) {
    bool found = false;
    Target b = builtin_5316();
    if (b.build == build) { out = b; found = true; }
    FILE* f = fopen("stockhook_targets.txt", "r");
    if (!f) return found;
    char line[1024];
    int lineno = 0;
    while (fgets(line, sizeof line, f)) {
        lineno++;
        char* hash = strchr(line, '#');
        if (hash) *hash = 0;
        bool blank = true;
        for (char* c = line; *c; c++) if (*c != ' ' && *c != '\t' && *c != '\r' && *c != '\n') blank = false;
        if (blank) continue;
        Target t;
        if (parse_target(line, t, lineno) && t.build == build) {
            // A line written before the colour hook keeps the built-in
            // colour target of the same build.
            if (!t.has_colour && b.build == build && b.has_colour) {
                t.has_colour = true; t.crva = b.crva; t.cstolen = b.cstolen;
                memcpy(t.csig, b.csig, sizeof t.csig); memcpy(t.cmask, b.cmask, sizeof t.cmask);
                t.csiglen = b.csiglen;
            }
            out = t;
            found = true;
            log_line("targets file, line %d: this build.", lineno);
        }
    }
    fclose(f);
    return found;
}

// =====================================================================
// THE EXE'S SECTIONS
// =====================================================================
// The loaded exe, read in place. A scan only ever reads inside a section
// the image maps readable, within its VirtualSize, so no read can fault.
static IMAGE_NT_HEADERS64* nt_headers() {
    auto dos = (IMAGE_DOS_HEADER*)g_base;
    return (IMAGE_NT_HEADERS64*)(g_base + dos->e_lfanew);
}

// .text, as a range.
static bool text_range(uint8_t*& lo, size_t& len) {
    auto nt = nt_headers();
    auto sec = IMAGE_FIRST_SECTION(nt);
    for (WORD s = 0; s < nt->FileHeader.NumberOfSections; s++, sec++) {
        if (memcmp(sec->Name, ".text", 5) != 0) continue;
        lo = (uint8_t*)(g_base + sec->VirtualAddress);
        len = sec->Misc.VirtualSize;
        return true;
    }
    return false;
}

// Is p inside .text with at least n bytes after it?
static bool in_text(const uint8_t* p, size_t n) {
    uint8_t* lo; size_t len;
    if (!text_range(lo, len)) return false;
    return p >= lo && p + n <= lo + len;
}

// Calls fn(lo, len) for every readable section; stops when fn returns true.
template <typename F> static bool each_readable(F fn) {
    auto nt = nt_headers();
    auto sec = IMAGE_FIRST_SECTION(nt);
    for (WORD s = 0; s < nt->FileHeader.NumberOfSections; s++, sec++) {
        if (!(sec->Characteristics & IMAGE_SCN_MEM_READ)) continue;
        if (fn((uint8_t*)(g_base + sec->VirtualAddress), (size_t)sec->Misc.VirtualSize)) return true;
    }
    return false;
}

// Is [p, p + n) inside one readable section?
static bool readable(const uint8_t* p, size_t n) {
    return each_readable([&](uint8_t* lo, size_t len) { return p >= lo && p + n <= lo + len; });
}

// Does the signature match at p (masked)?
static bool masked_at(const uint8_t* p, const uint8_t* sig, const uint8_t* mask, size_t n) {
    for (size_t i = 0; i < n; i++) if (mask[i] && p[i] != sig[i]) return false;
    return true;
}

// Every place in .text the signature matches: the count, and the first.
static int scan_text(const uint8_t* sig, const uint8_t* mask, size_t n, uint8_t*& found) {
    uint8_t* lo; size_t len;
    found = nullptr;
    if (!text_range(lo, len) || n == 0) return 0;
    int matches = 0;
    for (size_t i = 0; i + n <= len; i++) {
        if ((!mask[0] || lo[i] == sig[0]) && masked_at(lo + i, sig, mask, n)) {
            if (!found) found = lo + i;
            matches++;
        }
    }
    return matches;
}

// =====================================================================
// THE AUTOMATIC TARGET (layout 6, 2026-11-09)
// =====================================================================
// WHY: a build not listed used to hook nothing until someone listed it,
// and until a player noticed the update, Stockhook was off. DF 53.17 was
// listed by hand (2026-11-09) with four checks, all made from the exe
// alone; they are made here, by the DLL, at launch:
//   1. THE SIGNATURES: the 53.16 signatures (SIG_5316, CSIG_5316) must each
//      match exactly once in .text. They hold the stolen bytes whole, so a
//      match means the jump replaces the same instructions as before (19
//      and 15 bytes). The colour signature's list byte is left as ?? here
//      (THE LIST COUNT).
//   2. THE VTABLE (verify_vtable): the item vtable offsets the hook calls,
//      read off DF's own item classes through their RTTI (the names MSVC
//      keeps for every polymorphic class: ".?AVitem_barst@@" and so on), as
//      the hand check read them. Each slot's code must do what the hook
//      expects: return the item type constant, the subtype, an int16
//      mat_type, an int32 mat_index.
//   3. THE CHECK STILL READS THE MATERIAL: DF's stockpile check must call
//      the getMaterial and getMaterialIndex slots itself near its start
//      (53.17: call [rax+10h], call [rax+18h] at +0x135 and +0x143).
//   4. THE LIST COUNT: the colour function's switch bound is read and
//      published (list_max); Lua checks DFHack's stockpile_list covers it
//      before the colour hook folds anything (colour_ok).
// Any check that fails: no hook, and the reason goes to stockhook.log as
// the last line with NOT HOOKING in it, which RM's log and prompt show.
// A build listed in stockhook_targets.txt never comes here: a listed line
// is the way to hook a build these checks refuse.

// The reference target for a build not listed: the 53.16 signatures and
// stolen counts, no known RVA, the colour function's list byte open.
static Target automatic_target(uint32_t build) {
    Target t = builtin_5316();
    t.build = build;
    t.rva = 0;
    t.crva = 0;
    t.cmask[CSIG_LIST_BYTE] = 0;
    t.automatic = true;
    return t;
}

// ---- READING A FUNCTION'S FIRST INSTRUCTIONS ----
// The getters are one or two instructions and a ret. These read the
// encodings MSVC emits for them (all seen in 53.17, item_barst,
// item_boulderst, item_woodst, item_corpsest); anything else reads as
// "not this shape", which fails the check rather than guessing.
// An incremental-link thunk (jmp rel32) is followed once.
static const uint8_t* follow_thunk(const uint8_t* p) {
    if (in_text(p, 5) && p[0] == 0xE9) {
        int32_t rel; memcpy(&rel, p + 1, 4);
        const uint8_t* q = p + 5 + rel;
        if (in_text(q, 16)) return q;
    }
    return p;
}

// return <constant>: xor eax,eax / mov eax,imm32 / or eax,-1; then ret.
static bool body_const(const uint8_t* p, int32_t& v) {
    p = follow_thunk(p);
    if (!in_text(p, 16)) return false;
    if ((p[0] == 0x31 || p[0] == 0x33) && p[1] == 0xC0 && p[2] == 0xC3) { v = 0; return true; }
    if (p[0] == 0xB8 && p[5] == 0xC3) { memcpy(&v, p + 1, 4); return true; }
    if (p[0] == 0x83 && p[1] == 0xC8 && p[2] == 0xFF && p[3] == 0xC3) { v = -1; return true; }
    return false;
}

// return this-><field>: a load from [rcx + disp], then ret. width 2:
// movzx or movsx eax, word; width 4: mov eax, dword.
static bool body_load(const uint8_t* p, int width, uint32_t& disp) {
    p = follow_thunk(p);
    if (!in_text(p, 16)) return false;
    const uint8_t* m;
    if (width == 2 && p[0] == 0x0F && (p[1] == 0xB7 || p[1] == 0xBF)) m = p + 2;
    else if (width == 4 && p[0] == 0x8B) m = p + 1;
    else return false;
    if (m[0] == 0x81) {                        // [rcx + disp32]
        memcpy(&disp, m + 1, 4);
        return m[5] == 0xC3;
    }
    if (m[0] == 0x41) {                        // [rcx + disp8]
        disp = (uint32_t)(int32_t)(int8_t)m[1];
        return m[2] == 0xC3;
    }
    return false;
}

// ---- A CLASS'S VTABLE, THROUGH ITS RTTI ----
// MSVC x64 RTTI: a TypeDescriptor (vfptr 8, spare 8, then the decorated
// name); a CompleteObjectLocator (signature 1, offset, cdOffset, then the
// TypeDescriptor, ClassHierarchyDescriptor and the locator itself, each
// as an RVA); and the vtable, whose slot -1 holds the locator's address.
// Single inheritance: the locator with offset 0 is the class's own.
static const uint8_t* rtti_vtable(const char* cls) {
    char name[96];
    snprintf(name, sizeof name, ".?AV%s@@", cls);
    size_t nl = strlen(name) + 1;              // the name's NUL too
    const uint8_t* vt = nullptr;
    each_readable([&](uint8_t* lo, size_t len) {
        for (size_t i = 16; i + nl <= len; i++) {
            if (lo[i] != '.' || memcmp(lo + i, name, nl) != 0) continue;
            uint32_t td_rva = (uint32_t)((lo + i - 16) - (uint8_t*)g_base);
            // The locator naming this TypeDescriptor.
            uint32_t col_rva = 0;
            each_readable([&](uint8_t* clo, size_t clen) {
                for (size_t j = 0; j + 24 <= clen; j += 4) {
                    const uint32_t* c = (const uint32_t*)(clo + j);
                    if (c[3] != td_rva || c[0] != 1 || c[1] != 0) continue;
                    uint32_t self = (uint32_t)((clo + j) - (uint8_t*)g_base);
                    if (c[5] != self) continue;
                    col_rva = self;
                    return true;
                }
                return false;
            });
            if (!col_rva) continue;
            // The vtable: the slot after the locator's address.
            uint64_t want = (uint64_t)g_base + col_rva;
            each_readable([&](uint8_t* vlo, size_t vlen) {
                for (size_t j = 0; j + 16 <= vlen; j += 8) {
                    if (*(const uint64_t*)(vlo + j) != want) continue;
                    const uint8_t* cand = vlo + j + 8;
                    const uint8_t* first = *(const uint8_t* const*)cand;
                    if (in_text(first, 1)) { vt = cand; return true; }
                }
                return false;
            });
            if (vt) return true;
        }
        return false;
    });
    return vt;
}

// The function in slot off of vtable vt, or nullptr if it is not code.
static const uint8_t* slot_fn(const uint8_t* vt, size_t off) {
    if (!readable(vt + off, 8)) return nullptr;
    const uint8_t* f = *(const uint8_t* const*)(vt + off);
    return in_text(f, 16) ? f : nullptr;
}

// ---- CHECK 2: THE VTABLE ----
// What each slot must be, per class. type: DF's item_type value (BAR 0,
// BOULDER 4, WOOD 5, CORPSE 23, unchanged since long before 53.16).
// sub: 0 for a constant -1 (no subtype), 1 for a load (bars keep one),
// -1 not checked. mat: whether getMaterial and getMaterialIndex are
// checked (a corpse keeps no material). why: the reason, on failure.
struct VtExpect { const char* cls; int32_t type; int sub; bool mat; };
static const VtExpect VT_EXPECT[] = {
    { "item_barst",     0,  1, true  },
    { "item_boulderst", 4,  0, true  },
    { "item_woodst",    5,  0, true  },
    { "item_corpsest",  23, -1, false },
};

static bool verify_vtable(const size_t vt_off[4], char* why, size_t whylen) {
    for (const VtExpect& x : VT_EXPECT) {
        const uint8_t* vt = rtti_vtable(x.cls);
        if (!vt) { snprintf(why, whylen, "no RTTI vtable found for %s", x.cls); return false; }
        const uint8_t* f[4];
        for (int i = 0; i < 4; i++) {
            f[i] = slot_fn(vt, vt_off[i]);
            if (!f[i]) { snprintf(why, whylen, "%s: slot +0x%zX is not code", x.cls, vt_off[i]); return false; }
        }
        int32_t v;
        if (!body_const(f[0], v) || v != x.type) {
            snprintf(why, whylen, "%s: slot +0x%zX does not return item type %d", x.cls, vt_off[0], x.type);
            return false;
        }
        uint32_t d;
        if (x.sub == 0 && !(body_const(f[1], v) && v == -1)) {
            snprintf(why, whylen, "%s: slot +0x%zX does not return subtype -1", x.cls, vt_off[1]);
            return false;
        }
        if (x.sub == 1 && !body_load(f[1], 2, d)) {
            snprintf(why, whylen, "%s: slot +0x%zX does not read a subtype field", x.cls, vt_off[1]);
            return false;
        }
        if (x.mat) {
            uint32_t dt, di;
            if (!body_load(f[2], 2, dt)) {
                snprintf(why, whylen, "%s: slot +0x%zX does not read an int16 mat_type", x.cls, vt_off[2]);
                return false;
            }
            if (!body_load(f[3], 4, di)) {
                snprintf(why, whylen, "%s: slot +0x%zX does not read an int32 mat_index", x.cls, vt_off[3]);
                return false;
            }
            // mat_index follows mat_type in every item class (df-structures,
            // item_actualst's subclasses; 53.17 bars 0xBA, 0xBC).
            if (di <= dt || di > dt + 8) {
                snprintf(why, whylen, "%s: mat_type at +0x%X and mat_index at +0x%X are not neighbours",
                    x.cls, dt, di);
                return false;
            }
        }
    }
    return true;
}

// ---- CHECK 3: THE CHECK STILL READS THE MATERIAL ----
// call qword [reg + disp8] (FF 50+reg disp8) for both material slots in
// the first CALL_WINDOW bytes of DF's check. reg: rax, rcx, rdx, rbx, rsi
// or rdi (rsp and rbp need other encodings). 53.17: both through rax.
static const size_t CALL_WINDOW = 0x400;
static bool calls_slot(const uint8_t* fn, size_t off) {
    if (off > 0x7F || !in_text(fn, CALL_WINDOW)) return false;
    for (size_t i = 0; i + 3 <= CALL_WINDOW; i++) {
        uint8_t m = fn[i + 1];
        if (fn[i] == 0xFF && (m == 0x50 || m == 0x51 || m == 0x52 || m == 0x53 || m == 0x56 || m == 0x57)
            && fn[i + 2] == (uint8_t)off) return true;
    }
    return false;
}

// ---- CHECK 4: THE LIST COUNT ----
// The colour function's switch: cmp edx, imm8 then ja (0F 87 rel32 or 77
// rel8) in its first bytes. The imm8 is the highest list DF handles there
// (53.16 and 53.17: 6Ch, 108). false when the shape is not found.
static bool switch_bound(const uint8_t* fn, uint32_t& bound) {
    if (!in_text(fn, 128)) return false;
    for (size_t i = 0; i + 5 <= 128; i++) {
        if (fn[i] == 0x83 && fn[i + 1] == 0xFA
            && ((fn[i + 3] == 0x0F && fn[i + 4] == 0x87) || fn[i + 3] == 0x77)) {
            bound = fn[i + 2];
            return true;
        }
    }
    return false;
}

// ---- A READY-MADE TARGETS LINE ----
// For a verified build: the line that lists it, so it can go in
// stockhook_targets.txt and skip the checks (and the scans) at later
// launches. The colour part pins the list byte as found.
static void log_targets_line(uint32_t build, uint32_t rva, const uint8_t* cfn) {
    char buf[1024];
    size_t n = 0;
    auto put = [&](const char* fmt, ...) {
        if (n >= sizeof buf) return;
        va_list ap; va_start(ap, fmt);
        int w = vsnprintf(buf + n, sizeof buf - n, fmt, ap);
        va_end(ap);
        if (w > 0) n += (size_t)w;
    };
    put("build %X rva %X stolen %zX vt %zX %zX %zX %zX sig", build, rva, g_tgt.stolen,
        g_tgt.vt[0], g_tgt.vt[1], g_tgt.vt[2], g_tgt.vt[3]);
    for (size_t i = 0; i < g_tgt.siglen; i++)
        put(g_tgt.mask[i] ? " %02X" : " ??", g_tgt.sig[i]);
    if (cfn) {
        put(" crva %X cstolen %zX csig", (uint32_t)(cfn - (uint8_t*)g_base), g_tgt.cstolen);
        for (size_t i = 0; i < g_tgt.csiglen; i++) {
            // The cookie stays ??; the list byte is written as found. The
            // rest comes from the signature, never from cfn: the colour
            // hook's jump has already replaced the function's first bytes
            // (MEASURED in the offline harness, 2026-11-09: the line came
            // out starting FF 25, the jump).
            bool open = !g_tgt.cmask[i] && i != CSIG_LIST_BYTE;
            uint8_t b = (i == CSIG_LIST_BYTE) ? cfn[i] : g_tgt.csig[i];
            put(open ? " ??" : " %02X", b);
        }
    }
    log_line("automatic: this line in stockhook_targets.txt lists the build and skips these checks:");
    log_line("%s", buf);
}

// =====================================================================
// FINDING THE TARGET
// =====================================================================
static uint8_t* find_target() {
    auto nt = nt_headers();
    uint32_t build = nt->FileHeader.TimeDateStamp;
    log_line("DF build (PE timestamp) 0x%08X.", build);

    // ---- A LISTED BUILD, ELSE THE AUTOMATIC TARGET ----
    // See DF UPDATES at the top.
    if (!pick_target(build, g_tgt)) {
        log_line("target: build 0x%08X is not listed (built in, or a line in stockhook_targets.txt);"
            " checking it (THE AUTOMATIC TARGET).", build);
        g_tgt = automatic_target(build);
    }
    VT_GET_TYPE = g_tgt.vt[0];
    VT_GET_SUBTYPE = g_tgt.vt[1];
    VT_GET_MAT_TYPE = g_tgt.vt[2];
    VT_GET_MAT_INDEX = g_tgt.vt[3];

    uint8_t* at = nullptr;
    if (!g_tgt.automatic) {
        uint8_t* known = (uint8_t*)(g_base + g_tgt.rva);
        if (in_text(known, g_tgt.siglen) && masked_at(known, g_tgt.sig, g_tgt.mask, g_tgt.siglen)) {
            log_line("target: found at the known RVA 0x%X", g_tgt.rva);
            return known;
        }
    }
    uint8_t* found;
    int matches = scan_text(g_tgt.sig, g_tgt.mask, g_tgt.siglen, found);
    if (matches != 1) {
        log_line(g_tgt.automatic
            ? "automatic: the stockpile check's reference signature matched %d times (need exactly 1)."
              " NOT HOOKING: this DF build changed the check; it needs a line in stockhook_targets.txt."
            : "target: signature matched %d times (need exactly 1). NOT HOOKING.", matches);
        return nullptr;
    }
    at = found;
    log_line(g_tgt.automatic ? "automatic: check 1, the stockpile check found by scan at RVA 0x%llX."
                             : "target: not at the known RVA; found by scan at RVA 0x%llX",
        (unsigned long long)(at - (uint8_t*)g_base));
    if (!g_tgt.automatic) return at;

    // ---- THE AUTOMATIC CHECKS 2 AND 3 ----
    // Check 1's colour half and check 4 are the colour hook's (find_colour).
    char why[256] = "";
    if (!verify_vtable(g_tgt.vt, why, sizeof why)) {
        log_line("automatic: check 2 failed: %s. NOT HOOKING: the item vtable may have moved;"
            " this DF build needs a line in stockhook_targets.txt.", why);
        return nullptr;
    }
    log_line("automatic: check 2, the item vtable: getType +0x%zX, getSubtype +0x%zX, getMaterial +0x%zX,"
        " getMaterialIndex +0x%zX, read through RTTI on item_barst, item_boulderst, item_woodst and"
        " item_corpsest.", g_tgt.vt[0], g_tgt.vt[1], g_tgt.vt[2], g_tgt.vt[3]);
    if (!calls_slot(at, g_tgt.vt[2]) || !calls_slot(at, g_tgt.vt[3])) {
        log_line("automatic: check 3 failed: the stockpile check does not call the item's +0x%zX and"
            " +0x%zX slots near its start. NOT HOOKING: this DF build needs a line in"
            " stockhook_targets.txt.", g_tgt.vt[2], g_tgt.vt[3]);
        return nullptr;
    }
    log_line("automatic: check 3, the stockpile check calls the item's +0x%zX and +0x%zX slots.",
        g_tgt.vt[2], g_tgt.vt[3]);
    return at;
}

// ---- THE COLOUR FUNCTION ----
// At its known RVA, else by a scan of .text that must match exactly once.
// Its switch bound is read and published either way (THE LIST COUNT).
static uint8_t* find_colour() {
    if (!g_tgt.has_colour) { log_line("colour: no colour target for this build; categories keep DF's colours."); return nullptr; }
    uint8_t* at = nullptr;
    if (!g_tgt.automatic) {
        uint8_t* known = (uint8_t*)(g_base + g_tgt.crva);
        if (in_text(known, g_tgt.csiglen) && masked_at(known, g_tgt.csig, g_tgt.cmask, g_tgt.csiglen)) {
            log_line("colour: found at the known RVA 0x%X", g_tgt.crva);
            at = known;
        }
    }
    if (!at) {
        uint8_t* found;
        int matches = scan_text(g_tgt.csig, g_tgt.cmask, g_tgt.csiglen, found);
        if (matches != 1) {
            log_line("colour: signature matched %d times (need exactly 1); categories keep DF's colours.", matches);
            return nullptr;
        }
        at = found;
        log_line(g_tgt.automatic ? "automatic: check 1, the colour function found by scan at RVA 0x%llX."
                                 : "colour: not at the known RVA; found by scan at RVA 0x%llX",
            (unsigned long long)(at - (uint8_t*)g_base));
    }
    uint32_t bound;
    if (!switch_bound(at, bound) || bound >= (uint32_t)N_LISTS) {
        log_line("colour: the list switch was not read; categories keep DF's colours.");
        return nullptr;
    }
    g_block.list_max = bound;
    log_line("colour: DF's colour function handles lists 0 to %u; Lua checks DFHack's list count"
        " covers them before the hook folds anything.", bound);
    return at;
}

static void write_abs_jmp(uint8_t* at, const void* dest) {
    at[0] = 0xFF; at[1] = 0x25;                 // jmp qword ptr [rip+0]
    at[2] = at[3] = at[4] = at[5] = 0x00;
    uint64_t d = (uint64_t)dest;
    memcpy(at + 6, &d, 8);
}

static bool install() {
    g_target = find_target();
    if (!g_target) return false;

    // The trampoline: DF's stolen instructions, then a jump back into DF
    // just after them. Calling it runs DF's original function in full.
    uint8_t* tramp = (uint8_t*)VirtualAlloc(nullptr, 64,
        MEM_COMMIT | MEM_RESERVE, PAGE_EXECUTE_READWRITE);
    if (!tramp) { log_line("VirtualAlloc failed (%lu). NOT HOOKING.", GetLastError()); return false; }
    memcpy(tramp, g_target, g_tgt.stolen);
    write_abs_jmp(tramp + g_tgt.stolen, g_target + g_tgt.stolen);
    g_original = (accept_fn)tramp;

    DWORD old;
    if (!VirtualProtect(g_target, g_tgt.stolen, PAGE_EXECUTE_READWRITE, &old)) {
        log_line("VirtualProtect failed (%lu). NOT HOOKING.", GetLastError());
        return false;
    }
    memcpy(g_saved, g_target, g_tgt.stolen);
    write_abs_jmp(g_target, (const void*)&hook);
    memset(g_target + JMP_LEN, 0x90, g_tgt.stolen - JMP_LEN);
    VirtualProtect(g_target, g_tgt.stolen, old, &old);
    FlushInstructionCache(GetCurrentProcess(), g_target, g_tgt.stolen);
    return true;
}

// The colour hook, the same way: DF's stolen instructions in a trampoline,
// a jump to colour_hook in their place. Only once the stockpile check is
// hooked; its failure leaves that hook as it is.
static bool install_colour() {
    g_ctarget = find_colour();
    if (!g_ctarget) return false;
    uint8_t* tramp = (uint8_t*)VirtualAlloc(nullptr, 64,
        MEM_COMMIT | MEM_RESERVE, PAGE_EXECUTE_READWRITE);
    if (!tramp) { log_line("colour: VirtualAlloc failed (%lu).", GetLastError()); return false; }
    memcpy(tramp, g_ctarget, g_tgt.cstolen);
    write_abs_jmp(tramp + g_tgt.cstolen, g_ctarget + g_tgt.cstolen);
    g_colour_original = (state_fn)tramp;
    DWORD old;
    if (!VirtualProtect(g_ctarget, g_tgt.cstolen, PAGE_EXECUTE_READWRITE, &old)) {
        log_line("colour: VirtualProtect failed (%lu).", GetLastError());
        return false;
    }
    memcpy(g_csaved, g_ctarget, g_tgt.cstolen);
    write_abs_jmp(g_ctarget, (const void*)&colour_hook);
    memset(g_ctarget + JMP_LEN, 0x90, g_tgt.cstolen - JMP_LEN);
    VirtualProtect(g_ctarget, g_tgt.cstolen, old, &old);
    FlushInstructionCache(GetCurrentProcess(), g_ctarget, g_tgt.cstolen);
    return true;
}

static void uninstall_colour() {
    if (!g_chooked) return;
    DWORD old;
    if (VirtualProtect(g_ctarget, g_tgt.cstolen, PAGE_EXECUTE_READWRITE, &old)) {
        memcpy(g_ctarget, g_csaved, g_tgt.cstolen);
        VirtualProtect(g_ctarget, g_tgt.cstolen, old, &old);
        FlushInstructionCache(GetCurrentProcess(), g_ctarget, g_tgt.cstolen);
        g_chooked = false;
        g_block.colour_hooked = 0;
    }
}

static void uninstall() {
    if (!g_hooked) return;
    DWORD old;
    if (VirtualProtect(g_target, g_tgt.stolen, PAGE_EXECUTE_READWRITE, &old)) {
        memcpy(g_target, g_saved, g_tgt.stolen);
        VirtualProtect(g_target, g_tgt.stolen, old, &old);
        FlushInstructionCache(GetCurrentProcess(), g_target, g_tgt.stolen);
        g_hooked = false;
        g_block.hooked = 0;
    }
}

// =====================================================================
// THE DFHOOKS ENTRY POINTS
// =====================================================================
// init runs once at startup, before any fort is loaded, so the patch never
// lands while DF is inside the function.

extern "C" __declspec(dllexport) void dfhooks_init() {
    g_log = fopen("stockhook.log", "w");
    g_base = (uintptr_t)GetModuleHandleW(nullptr);
    log_line("Stockhook DLL, layout %u. DF image base 0x%llX", LAYOUT,
        (unsigned long long)g_base);

    // ---- THE BLOCK, PUBLISHED ----
    // Published whether or not the hook installs, so Lua can read
    // 'hooked' and say why it is falling back.
    memcpy(g_block.magic, "STKHOOK1", 8);
    g_block.layout = LAYOUT;
    char addr[32];
    snprintf(addr, sizeof addr, "%llX", (unsigned long long)(uintptr_t)&g_block);
    // _putenv_s updates the C runtime's environment, which DFHack's Lua
    // reads through os.getenv (both use the shared UCRT).
    if (_putenv_s("STOCKHOOK_BLOCK", addr) != 0) log_line("could not publish STOCKHOOK_BLOCK.");
    else log_line("block published at 0x%s (%u bytes).", addr, (unsigned)sizeof(Block));

    if (GetFileAttributesA("stockhook.disable") != INVALID_FILE_ATTRIBUTES) {
        log_line("stockhook.disable present. NOT HOOKING.");
        return;
    }
    g_hooked = install();
    g_block.hooked = g_hooked ? 1 : 0;
    g_block.automatic = (g_hooked && g_tgt.automatic) ? 1 : 0;
    log_line(g_hooked ? (g_tgt.automatic ? "hook installed (a verified build not listed)." : "hook installed.")
                      : "hook not installed.");
    if (g_hooked) {
        g_chooked = install_colour();
        g_block.colour_hooked = g_chooked ? 1 : 0;
        log_line(g_chooked ? "colour hook installed." : "colour hook not installed.");
        if (g_tgt.automatic) log_targets_line(g_tgt.build, (uint32_t)(g_target - (uint8_t*)g_base),
                                              g_chooked ? g_ctarget : nullptr);
    }
}

extern "C" __declspec(dllexport) void dfhooks_shutdown() {
    g_block.enabled = 0;
    uninstall_colour();
    uninstall();
    log_line("shutdown: calls %lld, yes %lld, no %lld, passed %lld; original bytes restored.",
        (long long)g_block.calls, (long long)g_block.yes,
        (long long)g_block.no, (long long)g_block.passed);
    if (g_log) { fclose(g_log); g_log = nullptr; }
}