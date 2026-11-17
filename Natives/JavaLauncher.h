#pragma once

#include <Foundation/Foundation.h>
#include "jni.h"

typedef jint JLI_Launch_func(int argc, const char ** argv, /* main argc, argc */
        int jargc, const char** jargv,          /* java args */
        int appclassc, const char** appclassv,  /* app classpath */
        const char* fullversion,                /* full version defined */
        const char* dotversion,                 /* dot version defined */
        const char* pname,                      /* program name */
        const char* lname,                      /* launcher name */
        jboolean javaargs,                      /* JAVA_ARGS */
        jboolean cpwildcard,                    /* classpath wildcard*/
        jboolean javaw,                         /* windows-only javaw */
        jint ergo                               /* ergonomics class policy */
);
JLI_Launch_func *pJLI_Launch;

int launchJVM(NSString *username, id launchTarget, int width, int height, int minVersion);

// Runs an official NeoForge installer without presenting its desktop Swing UI.
// `installationDirectory` is a private staging game directory, never GAME_DIR.
// The completion runs on the caller's background queue after the installer returns.
void launchNeoForgeInstaller(NSString *installerPath, NSString *versionID, NSString *installationDirectory,
                             void (^completion)(BOOL installed, NSString *errorMessage));
