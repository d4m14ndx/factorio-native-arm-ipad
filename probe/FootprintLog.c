#include <mach/mach.h>
#include <mach/vm_statistics.h>
#include <malloc/malloc.h>
#include <os/proc.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

// Logs the memory iOS counts against the app's limit every 2 seconds, and splits it
// by owner every 16 seconds or after 256 MB of growth. "graphics" is Metal's share
// from the kernel ledger; the rest is dirty and compressed memory per VM tag. At most
// once a minute it also counts live malloc blocks of 64 KB and up by size.

enum { Bins=1024 };
static uint64_t binKey[Bins], binCount[Bins], binBytes[Bins], mediumCount, mediumBytes, otherCount, otherBytes;

static kern_return_t ReadLocal(task_t task, vm_address_t address, vm_size_t size, void **local) {
    (void)task; (void)size;
    *local=(void *)address;
    return KERN_SUCCESS;
}

// Runs with the zone locked, so it must not allocate.
static void RecordBlocks(task_t task, void *context, unsigned type, vm_range_t *ranges, unsigned count) {
    (void)task; (void)context; (void)type;
    for (unsigned i=0;i<count;i++) {
        uint64_t size=ranges[i].size;
        if (size<(64<<10)) continue;
        if (size<(1<<20)) { mediumCount++; mediumBytes+=size; continue; }
        uint64_t key=(size+(32<<10))>>16; // nearest 64 KB
        unsigned slot=(unsigned)(key*2654435761u%Bins), probe=0;
        while (probe<Bins && binKey[slot] && binKey[slot]!=key) { slot=(slot+1)%Bins; probe++; }
        if (probe==Bins) { otherCount++; otherBytes+=size; continue; }
        binKey[slot]=key; binCount[slot]++; binBytes[slot]+=size;
    }
}

static int CompareSizes(const void *a, const void *b);
extern unsigned FilePagesInUse(void);

static void LogLargeBlocks(void) {
    vm_address_t *zones=NULL;
    unsigned zoneCount=0;
    if (malloc_get_all_zones(mach_task_self(),ReadLocal,&zones,&zoneCount)!=KERN_SUCCESS) return;
    memset(binKey,0,sizeof binKey); memset(binCount,0,sizeof binCount); memset(binBytes,0,sizeof binBytes);
    mediumCount=mediumBytes=otherCount=otherBytes=0;
    uint64_t start=clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    for (unsigned i=0;i<zoneCount;i++) {
        malloc_zone_t *zone=(malloc_zone_t *)zones[i];
        if (!zone || !zone->introspect || !zone->introspect->enumerator || !zone->introspect->force_lock) continue;
        zone->introspect->force_lock(zone);
        zone->introspect->enumerator(mach_task_self(),NULL,MALLOC_PTR_IN_USE_RANGE_TYPE,zones[i],ReadLocal,RecordBlocks);
        zone->introspect->force_unlock(zone);
    }
    uint64_t ms=(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)-start)/1000000;
    static uint64_t sorted[Bins][2];
    uint64_t count=0, bytes=0;
    for (unsigned i=0;i<Bins;i++) {
        sorted[i][0]=binBytes[i]; sorted[i][1]=i;
        count+=binCount[i]; bytes+=binBytes[i];
    }
    qsort(sorted,Bins,sizeof sorted[0],CompareSizes);
    char line[1024];
    int length=snprintf(line,sizeof line,"FPI_LARGE: %llu MB in %llu blocks of 1 MB+, %llu MB in %llu of 64 KB-1 MB, %u zones, %llu ms |",
                        (bytes+otherBytes)>>20,count+otherCount,mediumBytes>>20,mediumCount,zoneCount,ms);
    for (unsigned i=0;i<12 && sorted[i][0]>=(8<<20) && length<(int)sizeof line-48;i++) {
        unsigned slot=(unsigned)sorted[i][1];
        length+=snprintf(line+length,sizeof line-length," %.2f MB x%llu = %llu,",
                         binKey[slot]/16.0,binCount[slot],binBytes[slot]>>20);
    }
    if (line[length-1]==',') line[length-1]=0;
    fprintf(stderr,"%s\n",line);
}

static const char *TagName(unsigned tag) {
    switch (tag) {
    case 0: return "untagged";
    case VM_MEMORY_MALLOC: return "malloc";
    case VM_MEMORY_MALLOC_TINY: case VM_MEMORY_MALLOC_NANO: return "malloc-tiny";
    case VM_MEMORY_MALLOC_SMALL: return "malloc-small";
    case VM_MEMORY_MALLOC_MEDIUM: return "malloc-medium";
    case VM_MEMORY_MALLOC_LARGE: case VM_MEMORY_MALLOC_LARGE_REUSABLE:
    case VM_MEMORY_MALLOC_LARGE_REUSED: return "malloc-large";
    case VM_MEMORY_MALLOC_HUGE: return "malloc-huge";
    case VM_MEMORY_IOKIT: return "iokit";
    case VM_MEMORY_STACK: return "stack";
    case VM_MEMORY_DYLD: case VM_MEMORY_DYLD_MALLOC: return "dyld";
    case VM_MEMORY_IOSURFACE: return "iosurface";
    case VM_MEMORY_IOACCELERATOR: return "ioaccelerator";
    default: return NULL;
    }
}

static int CompareSizes(const void *a, const void *b) {
    uint64_t x=((const uint64_t *)a)[0], y=((const uint64_t *)b)[0];
    return x<y ? 1 : x>y ? -1 : 0;
}

static void LogBreakdown(const task_vm_info_data_t *vm) {
    uint64_t bytes[258]={0}; // 0-255 by tag, 256 dirty mapped files
    vm_address_t address=0;
    natural_t depth=0;
    for (;;) {
        vm_size_t size=0;
        vm_region_submap_info_data_64_t info;
        mach_msg_type_number_t count=VM_REGION_SUBMAP_INFO_COUNT_64;
        if (vm_region_recurse_64(mach_task_self(),&address,&size,&depth,(vm_region_recurse_info_t)&info,&count)!=KERN_SUCCESS) break;
        if (info.is_submap) { depth++; continue; }
        uint64_t used=(uint64_t)(info.pages_dirtied+info.pages_swapped_out)*vm_page_size;
        bytes[info.external_pager ? 256 : info.user_tag&255]+=used;
        address+=size;
    }
    uint64_t sorted[257][2];
    for (unsigned i=0;i<257;i++) { sorted[i][0]=bytes[i]; sorted[i][1]=i; }
    qsort(sorted,257,sizeof sorted[0],CompareSizes);
    char line[1024];
    int length=snprintf(line,sizeof line,"FPI_FOOTPRINT: %llu MB, graphics %lld, compressed %llu, file pages %u |",
                        vm->phys_footprint>>20,
                        (vm->ledger_tag_graphics_footprint+vm->ledger_tag_graphics_footprint_compressed)>>20,
                        vm->compressed>>20,FilePagesInUse()*16);
    for (unsigned i=0;i<12 && sorted[i][0]>=(8<<20) && length<(int)sizeof line-48;i++) {
        unsigned tag=(unsigned)sorted[i][1];
        const char *name=tag==256 ? "mapped-file" : TagName(tag);
        length+=name ? snprintf(line+length,sizeof line-length," %s %llu,",name,sorted[i][0]>>20)
                     : snprintf(line+length,sizeof line-length," tag%u %llu,",tag,sorted[i][0]>>20);
    }
    if (line[length-1]==',') line[length-1]=0;
    fprintf(stderr,"%s\n",line);
}

static void *FootprintLoop(void *unused) {
    (void)unused;
    uint64_t logged=0;
    unsigned sized=0;
    for (unsigned tick=1;;tick++) {
        sleep(2);
        task_vm_info_data_t vm;
        mach_msg_type_number_t count=TASK_VM_INFO_COUNT;
        if (task_info(mach_task_self(),TASK_VM_INFO,(task_info_t)&vm,&count)!=KERN_SUCCESS) continue;
        fprintf(stderr,"FPI_MEMORY: used %llu MB, free %zu MB\n",vm.phys_footprint>>20,os_proc_available_memory()>>20);
        if (tick%8==0 || vm.phys_footprint>logged+(256<<20)) {
            LogBreakdown(&vm);
            logged=vm.phys_footprint;
            if (tick>=sized+30) { LogLargeBlocks(); sized=tick; }
        }
    }
    return NULL;
}

void StartFootprintLog(void) {
    pthread_t thread;
    if (!pthread_create(&thread,NULL,FootprintLoop,NULL)) pthread_detach(thread);
}
