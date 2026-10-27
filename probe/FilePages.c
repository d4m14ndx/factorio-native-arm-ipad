#include <errno.h>
#include <fcntl.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>
#include <malloc/malloc.h>
#include <os/lock.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

// Factorio keeps its virtual atlas pages, about 1 GB with a big mod set, in 16 MB
// malloc blocks. iOS counts dirty anonymous memory against the app's limit but not
// dirty pages of a shared file mapping, which it can write out and drop instead. So
// the game's own malloc imports are rebound here, and blocks of that size come from
// slots in a mapping of an unlinked temporary file. A registered zone owns the slots,
// so a free from any other library still finds them. FPI_FILE_PAGES=0 turns this off.

enum { SlotCount=96 };
static const size_t SlotSize=16<<20;
static char *slots;
static bool used[SlotCount], written[SlotCount];
static unsigned inUse;
static os_unfair_lock lock=OS_UNFAIR_LOCK_INIT;

static bool Routed(size_t size) { return size>(15<<20) && size<=SlotSize; }
static bool Owns(const void *pointer) { return slots && (const char *)pointer>=slots && (const char *)pointer<slots+SlotCount*SlotSize; }

static void *Take(bool zeroed) {
    if (!slots) return NULL;
    int slot=-1;
    os_unfair_lock_lock(&lock);
    for (int i=0;i<SlotCount && slot<0;i++) if (!used[i]) slot=i;
    if (slot>=0) { used[slot]=true; inUse++; }
    bool dirty=slot>=0 && written[slot];
    if (slot>=0) written[slot]=true;
    os_unfair_lock_unlock(&lock);
    if (slot<0) return NULL;
    void *block=slots+slot*SlotSize;
    if (zeroed && dirty) memset(block,0,SlotSize); // Fresh slots read as zero from the sparse file.
    return block;
}

static void Release(void *pointer) {
    os_unfair_lock_lock(&lock);
    size_t slot=((char *)pointer-slots)/SlotSize;
    if (used[slot]) { used[slot]=false; inUse--; }
    os_unfair_lock_unlock(&lock);
}

static void *FileMalloc(size_t size) {
    void *block=Routed(size) ? Take(false) : NULL;
    return block ?: malloc(size);
}

static void *FileCalloc(size_t count, size_t size) {
    size_t total;
    void *block=!__builtin_mul_overflow(count,size,&total) && Routed(total) ? Take(true) : NULL;
    return block ?: calloc(count,size);
}

static int FilePosixMemalign(void **out, size_t alignment, size_t size) {
    void *block=Routed(size) && alignment<=(size_t)getpagesize() ? Take(false) : NULL;
    if (!block) return posix_memalign(out,alignment,size);
    *out=block;
    return 0;
}

static void FileFree(void *pointer) {
    if (Owns(pointer)) Release(pointer);
    else free(pointer);
}

static void *FileRealloc(void *pointer, size_t size) {
    if (!pointer) return FileMalloc(size);
    if (!Owns(pointer)) return realloc(pointer,size);
    if (size<=SlotSize && size) return pointer;
    void *moved=size ? malloc(size) : NULL;
    if (moved) memcpy(moved,pointer,SlotSize);
    if (moved || !size) Release(pointer);
    return moved;
}

static size_t ZoneSize(malloc_zone_t *zone, const void *pointer) { (void)zone; return Owns(pointer) ? SlotSize : 0; }
static void *ZoneMalloc(malloc_zone_t *zone, size_t size) { (void)zone; return malloc(size); }
static void *ZoneCalloc(malloc_zone_t *zone, size_t count, size_t size) { (void)zone; return calloc(count,size); }
static void *ZoneValloc(malloc_zone_t *zone, size_t size) { (void)zone; return valloc(size); }
static void ZoneFree(malloc_zone_t *zone, void *pointer) { (void)zone; if (Owns(pointer)) Release(pointer); }
static void *ZoneRealloc(malloc_zone_t *zone, void *pointer, size_t size) { (void)zone; return FileRealloc(pointer,size); }
static void ZoneDestroy(malloc_zone_t *zone) { (void)zone; }
static void ZoneFreeSized(malloc_zone_t *zone, void *pointer, size_t size) { (void)size; ZoneFree(zone,pointer); }
static void *ZoneMemalign(malloc_zone_t *zone, size_t alignment, size_t size) {
    (void)zone;
    void *block=NULL;
    return posix_memalign(&block,alignment,size) ? NULL : block;
}
static size_t ZoneGoodSize(malloc_zone_t *zone, size_t size) { (void)zone; return size; }
static boolean_t ZoneCheck(malloc_zone_t *zone) { (void)zone; return 1; }
static void ZonePrint(malloc_zone_t *zone, boolean_t verbose) { (void)zone; (void)verbose; }
static void ZoneLog(malloc_zone_t *zone, void *address) { (void)zone; (void)address; }
static void ZoneLock(malloc_zone_t *zone) { (void)zone; os_unfair_lock_lock(&lock); }
static void ZoneUnlock(malloc_zone_t *zone) { (void)zone; os_unfair_lock_unlock(&lock); }
static boolean_t ZoneLocked(malloc_zone_t *zone) { (void)zone; return 0; }
static void ZoneReinitLock(malloc_zone_t *zone) { (void)zone; lock=OS_UNFAIR_LOCK_INIT; }
static size_t ZonePressureRelief(malloc_zone_t *zone, size_t goal) { (void)zone; (void)goal; return 0; }
static void ZoneStatistics(malloc_zone_t *zone, malloc_statistics_t *stats) {
    (void)zone;
    *stats=(malloc_statistics_t){.blocks_in_use=inUse,.size_in_use=inUse*SlotSize,.max_size_in_use=inUse*SlotSize,.size_allocated=SlotCount*SlotSize};
}

static malloc_introspection_t introspection={
    .good_size=ZoneGoodSize, .check=ZoneCheck, .print=ZonePrint, .log=ZoneLog,
    .force_lock=ZoneLock, .force_unlock=ZoneUnlock, .statistics=ZoneStatistics, .zone_locked=ZoneLocked,
    .reinit_lock=ZoneReinitLock,
};

static malloc_zone_t zone={
    .size=ZoneSize, .malloc=ZoneMalloc, .calloc=ZoneCalloc, .valloc=ZoneValloc, .free=ZoneFree,
    .realloc=ZoneRealloc, .destroy=ZoneDestroy, .zone_name="FPI file pages", .introspect=&introspection,
    .version=9, .memalign=ZoneMemalign, .free_definite_size=ZoneFreeSized, .pressure_relief=ZonePressureRelief,
};

static const struct { const char *name; void *replacement; } hooks[]={
    {"_malloc",FileMalloc}, {"_calloc",FileCalloc}, {"_realloc",FileRealloc},
    {"_posix_memalign",FilePosixMemalign}, {"_free",FileFree},
};

// Points the image's lazy and non-lazy pointers for the hooked names at the wrappers.
static unsigned Rebind(const struct mach_header_64 *header, intptr_t slide) {
    const struct segment_command_64 *linkedit=NULL;
    const struct symtab_command *symtab=NULL;
    const struct dysymtab_command *dysymtab=NULL;
    const struct load_command *command=(const void *)(header+1);
    for (uint32_t i=0;i<header->ncmds;i++,command=(const void *)((const char *)command+command->cmdsize)) {
        if (command->cmd==LC_SEGMENT_64 && !strcmp(((const struct segment_command_64 *)command)->segname,SEG_LINKEDIT)) linkedit=(const void *)command;
        else if (command->cmd==LC_SYMTAB) symtab=(const void *)command;
        else if (command->cmd==LC_DYSYMTAB) dysymtab=(const void *)command;
    }
    if (!linkedit || !symtab || !dysymtab) return 0;
    uintptr_t base=(uintptr_t)slide+linkedit->vmaddr-linkedit->fileoff;
    const struct nlist_64 *symbols=(const void *)(base+symtab->symoff);
    const char *strings=(const char *)(base+symtab->stroff);
    const uint32_t *indirect=(const uint32_t *)(base+dysymtab->indirectsymoff);
    unsigned rebound=0;
    command=(const void *)(header+1);
    for (uint32_t i=0;i<header->ncmds;i++,command=(const void *)((const char *)command+command->cmdsize)) {
        if (command->cmd!=LC_SEGMENT_64) continue;
        const struct segment_command_64 *segment=(const void *)command;
        const struct section_64 *section=(const void *)(segment+1);
        for (uint32_t j=0;j<segment->nsects;j++,section++) {
            uint32_t type=section->flags&SECTION_TYPE;
            if (type!=S_LAZY_SYMBOL_POINTERS && type!=S_NON_LAZY_SYMBOL_POINTERS) continue;
            void **pointers=(void **)((uintptr_t)slide+section->addr);
            uintptr_t page=(uintptr_t)pointers&~(uintptr_t)(getpagesize()-1);
            size_t length=(uintptr_t)pointers+section->size-page;
            bool writable=false;
            for (uint64_t k=0;k<section->size/sizeof(void *);k++) {
                uint32_t index=indirect[section->reserved1+k];
                if (index&(INDIRECT_SYMBOL_LOCAL|INDIRECT_SYMBOL_ABS)) continue;
                const char *name=strings+symbols[index].n_un.n_strx;
                for (size_t h=0;h<sizeof hooks/sizeof hooks[0];h++) {
                    if (strcmp(name,hooks[h].name)) continue;
                    if (!writable && mprotect((void *)page,length,PROT_READ|PROT_WRITE)) {
                        fprintf(stderr,"FPI_FILE_PAGES: cannot write %s,%s: %s\n",segment->segname,section->sectname,strerror(errno));
                        return rebound;
                    }
                    writable=true;
                    pointers[k]=hooks[h].replacement;
                    rebound++;
                }
            }
            if (writable && (segment->flags&SG_READ_ONLY)) mprotect((void *)page,length,PROT_READ);
        }
    }
    return rebound;
}

unsigned FilePagesInUse(void) { return inUse; }

void InstallFilePages(void) {
    const char *setting=getenv("FPI_FILE_PAGES");
    if (setting && !strcmp(setting,"0")) { fprintf(stderr,"FPI_FILE_PAGES: off\n"); return; }
    char path[1024];
    snprintf(path,sizeof path,"%s/fpi-file-pages",getenv("TMPDIR") ?: "/tmp");
    int file=open(path,O_RDWR|O_CREAT|O_TRUNC,0600);
    if (file<0) { fprintf(stderr,"FPI_FILE_PAGES: open failed: %s\n",strerror(errno)); return; }
    unlink(path);
    void *mapped=ftruncate(file,(off_t)(SlotCount*SlotSize)) ? MAP_FAILED
                : mmap(NULL,SlotCount*SlotSize,PROT_READ|PROT_WRITE,MAP_SHARED,file,0);
    close(file); // The mapping keeps the file.
    if (mapped==MAP_FAILED) { fprintf(stderr,"FPI_FILE_PAGES: mapping failed: %s\n",strerror(errno)); return; }
    slots=mapped;
    malloc_zone_register(&zone);
    unsigned rebound=Rebind((const struct mach_header_64 *)_dyld_get_image_header(0),_dyld_get_image_vmaddr_slide(0));
    fprintf(stderr,"FPI_FILE_PAGES: %u imports rebound, %d slots of 16 MB\n",rebound,SlotCount);
}
