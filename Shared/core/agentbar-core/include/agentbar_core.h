#ifndef AGENTBAR_CORE_H
#define AGENTBAR_CORE_H
#include <stdint.h>
/* ABI v1: UTF-8 JSON metadata, no source IO. Buffer is library-owned until free. */
uint32_t agentbar_core_abi_version(void);
char *agentbar_core_parse_json(const char *input);
void agentbar_core_free(char *buffer);
#endif
