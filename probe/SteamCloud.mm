// Steam Cloud stand-in. The Mac Steam build loads player-data.json, which holds the
// factorio.com login and multiplayer name, only from Steam Cloud, and iOS has no Steam.
// tools/entrypoint.py binds these over the no-Steam context's cloud reads, so the game
// gets its own local copy in Documents/Factorio/user, where it keeps writing the file.
#import <Foundation/Foundation.h>
#include <string>
#include <sys/stat.h>

static std::string FPCloudPath(const std::string &name) {
    NSString *user=[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/Factorio/user"];
    return std::string(user.fileSystemRepresentation)+"/"+name;
}

// Each replaces a const member function, so the context comes first.
extern "C" bool FPICloudFileExists(const void *context, const std::string &name) {
    struct stat info;
    return stat(FPCloudPath(name).c_str(),&info)==0 && S_ISREG(info.st_mode);
}

extern "C" int64_t FPICloudFileTimestamp(const void *context, const std::string &name) {
    struct stat info;
    return stat(FPCloudPath(name).c_str(),&info)==0 ? info.st_mtime : -1;
}

#pragma clang diagnostic ignored "-Wreturn-type-c-linkage"
extern "C" std::string FPIReadCloudFile(const void *context, const std::string &name) {
    NSData *data=[NSData dataWithContentsOfFile:@(FPCloudPath(name).c_str())];
    return data ? std::string((const char *)data.bytes,data.length) : std::string();
}
