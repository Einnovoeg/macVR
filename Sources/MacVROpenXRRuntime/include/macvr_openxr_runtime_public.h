#ifndef MACVR_OPENXR_RUNTIME_H_
#define MACVR_OPENXR_RUNTIME_H_ 1

#define XR_EXTENSION_PROTOTYPES 1
#include "openxr/openxr_loader_negotiation.h"

#ifdef __cplusplus
extern "C" {
#endif

const char *macvrOpenXRRuntimeName(void);
const char *macvrOpenXRRuntimeVersion(void);

#ifdef __cplusplus
}
#endif

#endif
