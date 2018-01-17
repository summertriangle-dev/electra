#import <Foundation/Foundation.h>
#import "debug.h"
#import "kern_utils.h"
#import "patchfinder64.h"
#import "offsets.h"
#include "find_port.h"

extern mach_port_t tfpzero;
extern uint64_t kernel_base;
extern uint64_t kernel_slide;

extern mach_port_t user_client;
extern uint64_t fake_client;

unsigned offsetof_p_pid = 0x10;               // proc_t::p_pid
unsigned offsetof_task = 0x18;                // proc_t::task
unsigned offsetof_p_uid = 0x30;               // proc_t::p_uid
unsigned offsetof_p_gid = 0x34;               // proc_t::p_uid
unsigned offsetof_p_ruid = 0x38;              // proc_t::p_uid
unsigned offsetof_p_rgid = 0x3c;              // proc_t::p_uid
unsigned offsetof_p_ucred = 0x100;            // proc_t::p_ucred
unsigned offsetof_p_csflags = 0x2a8;          // proc_t::p_csflags
unsigned offsetof_itk_self = 0xD8;            // task_t::itk_self (convert_task_to_port)
unsigned offsetof_itk_sself = 0xE8;           // task_t::itk_sself (task_get_special_port)
unsigned offsetof_itk_bootstrap = 0x2b8;      // task_t::itk_bootstrap (task_get_special_port)
unsigned offsetof_ip_mscount = 0x9C;          // ipc_port_t::ip_mscount (ipc_port_make_send)
unsigned offsetof_ip_srights = 0xA0;          // ipc_port_t::ip_srights (ipc_port_make_send)
unsigned offsetof_p_textvp = 0x248;           // proc_t::p_textvp
unsigned offsetof_p_textoff = 0x250;          // proc_t::p_textoff
unsigned offsetof_p_cputype = 0x2c0;          // proc_t::p_cputype
unsigned offsetof_p_cpu_subtype = 0x2c4;      // proc_t::p_cpu_subtype
unsigned offsetof_special = 2 * sizeof(long); // host::special

unsigned offsetof_ucred_cr_uid = 0x18;        // ucred::cr_uid
unsigned offsetof_ucred_cr_ruid = 0x1c;       // ucred::cr_ruid
unsigned offsetof_ucred_cr_svuid = 0x20;      // ucred::cr_svuid

unsigned offsetof_v_type = 0x70;              // vnode::v_type
unsigned offsetof_v_id = 0x74;                // vnode::v_id
unsigned offsetof_v_ubcinfo = 0x78;           // vnode::v_ubcinfo

unsigned offsetof_ubcinfo_csblobs = 0x50;     // ubc_info::csblobs

unsigned offsetof_csb_cputype = 0x8;          // cs_blob::csb_cputype
unsigned offsetof_csb_flags = 0x12;           // cs_blob::csb_flags
unsigned offsetof_csb_base_offset = 0x16;     // cs_blob::csb_base_offset
unsigned offsetof_csb_entitlements_offset = 0x98; // cs_blob::csb_entitlements
unsigned offsetof_csb_signer_type = 0xA0;     // cs_blob::csb_signer_type
unsigned offsetof_csb_platform_binary = 0xA4; // cs_blob::csb_platform_binary
unsigned offsetof_csb_platform_path = 0xA8;   // cs_blob::csb_platform_path

unsigned offsetof_t_flags = 0x3a0; // task::t_flags

#define TF_PLATFORM 0x400

#define	CS_VALID		0x0000001	/* dynamically valid */
#define CS_ADHOC		0x0000002	/* ad hoc signed */
#define CS_GET_TASK_ALLOW	0x0000004	/* has get-task-allow entitlement */
#define CS_INSTALLER		0x0000008	/* has installer entitlement */

#define	CS_HARD			0x0000100	/* don't load invalid pages */
#define	CS_KILL			0x0000200	/* kill process if it becomes invalid */
#define CS_CHECK_EXPIRATION	0x0000400	/* force expiration checking */
#define CS_RESTRICT		0x0000800	/* tell dyld to treat restricted */
#define CS_ENFORCEMENT		0x0001000	/* require enforcement */
#define CS_REQUIRE_LV		0x0002000	/* require library validation */
#define CS_ENTITLEMENTS_VALIDATED	0x0004000

#define	CS_ALLOWED_MACHO	0x00ffffe

#define CS_EXEC_SET_HARD	0x0100000	/* set CS_HARD on any exec'ed process */
#define CS_EXEC_SET_KILL	0x0200000	/* set CS_KILL on any exec'ed process */
#define CS_EXEC_SET_ENFORCEMENT	0x0400000	/* set CS_ENFORCEMENT on any exec'ed process */
#define CS_EXEC_SET_INSTALLER	0x0800000	/* set CS_INSTALLER on any exec'ed process */

#define CS_KILLED		0x1000000	/* was killed by kernel for invalidity */
#define CS_DYLD_PLATFORM	0x2000000	/* dyld used to load this is a platform binary */
#define CS_PLATFORM_BINARY	0x4000000	/* this is a platform binary */
#define CS_PLATFORM_PATH	0x8000000	/* platform binary by the fact of path (osx only) */

#define CS_DEBUGGED         0x10000000  /* process is currently or has previously been debugged and allowed to run with invalid pages */
#define CS_SIGNED         0x20000000  /* process has a signature (may have gone invalid) */
#define CS_DEV_CODE         0x40000000  /* code is dev signed, cannot be loaded into prod signed code (will go away with rdar://problem/28322552) */

size_t kread(uint64_t where, void *p, size_t size) {
	int rv;
	size_t offset = 0;
	while (offset < size) {
		mach_vm_size_t sz, chunk = 2048;
		if (chunk > size - offset) {
			chunk = size - offset;
		}
		rv = mach_vm_read_overwrite(tfpzero, where + offset, chunk, (mach_vm_address_t)p + offset, &sz);
		if (rv || sz == 0) {
			fprintf(stderr, "[e] error reading kernel @%p\n", (void *)(offset + where));
			break;
		}
		offset += sz;
	}
	return offset;
}

size_t kwrite(uint64_t where, const void *p, size_t size) {
	int rv;
	size_t offset = 0;
	while (offset < size) {
		size_t chunk = 2048;
		if (chunk > size - offset) {
			chunk = size - offset;
		}
		rv = mach_vm_write(tfpzero, where + offset, (mach_vm_offset_t)p + offset, chunk);
		if (rv) {
			fprintf(stderr, "[e] error writing kernel @%p\n", (void *)(offset + where));
			break;
		}
		offset += chunk;
	}
	return offset;
}

uint64_t kalloc(vm_size_t size){
	mach_vm_address_t address = 0;
	mach_vm_allocate(tfpzero, (mach_vm_address_t *)&address, size, VM_FLAGS_ANYWHERE);
	return address;
}

uint32_t rk32(uint64_t kaddr) {
  kern_return_t err;
  uint32_t val = 0;
  mach_vm_size_t outsize = 0;

  err = mach_vm_read_overwrite(tfpzero,
                               (mach_vm_address_t)kaddr,
                               (mach_vm_size_t)sizeof(uint32_t),
                               (mach_vm_address_t)&val,
                               &outsize);
  if (err != KERN_SUCCESS){
    printf("tfp0 read failed %s addr: 0x%llx err:%x port:%x\n", mach_error_string(err), kaddr, err, tfpzero);
    sleep(3);
    return 0;
  }

  if (outsize != sizeof(uint32_t)){
    printf("tfp0 read was short (expected %lx, got %llx\n", sizeof(uint32_t), outsize);
    sleep(3);
    return 0;
  }
  return val;
}

uint64_t rk64(uint64_t kaddr) {
  uint64_t lower = rk32(kaddr);
  uint64_t higher = rk32(kaddr+4);
  uint64_t full = ((higher<<32) | lower);
  return full;
}

void wk32(uint64_t kaddr, uint32_t val) {
  if (tfpzero == MACH_PORT_NULL) {
    printf("attempt to write to kernel memory before any kernel memory write primitives available\n");
    sleep(3);
    return;
  }

  kern_return_t err;
  err = mach_vm_write(tfpzero,
                      (mach_vm_address_t)kaddr,
                      (vm_offset_t)&val,
                      (mach_msg_type_number_t)sizeof(uint32_t));

  if (err != KERN_SUCCESS) {
    printf("tfp0 write failed: %s %x\n", mach_error_string(err), err);
    return;
  }
}

void wk64(uint64_t kaddr, uint64_t val) {
  uint32_t lower = (uint32_t)(val & 0xffffffff);
  uint32_t higher = (uint32_t)(val >> 32);
  wk32(kaddr, lower);
  wk32(kaddr+4, higher);
}

mach_port_t prepare_user_client() {
  kern_return_t err;
  mach_port_t user_client;
  io_service_t service = IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceMatching("IOSurfaceRoot"));

  if (service == IO_OBJECT_NULL){
    printf(" [-] unable to find service\n");
    exit(EXIT_FAILURE);
  }

  err = IOServiceOpen(service, mach_task_self(), 0, &user_client);
  if (err != KERN_SUCCESS){
    printf(" [-] unable to get user client connection\n");
    exit(EXIT_FAILURE);
  }


  printf("got user client: 0x%x\n", user_client);
  return user_client;
}

uint64_t find_port_address(mach_port_name_t port, int disposition) {
  return find_port_via_proc_pidlistuptrs_bug(port, disposition);
}

uint64_t cached_task_self_addr = 0;
uint64_t task_self_addr() {
  if (cached_task_self_addr == 0) {
    cached_task_self_addr = find_port_address(mach_task_self(), MACH_MSG_TYPE_COPY_SEND);
    printf("task self: 0x%llx\n", cached_task_self_addr);
  }
  return cached_task_self_addr;
}

uint64_t find_port(mach_port_name_t port){
  uint64_t task_port_addr = task_self_addr();

  uint64_t task_addr = rk64(task_port_addr + koffset(KSTRUCT_OFFSET_IPC_PORT_IP_KOBJECT));

  uint64_t itk_space = rk64(task_addr + koffset(KSTRUCT_OFFSET_TASK_ITK_SPACE));

  uint64_t is_table = rk64(itk_space + koffset(KSTRUCT_OFFSET_IPC_SPACE_IS_TABLE));

  uint32_t port_index = port >> 8;
  const int sizeof_ipc_entry_t = 0x18;

  uint64_t port_addr = rk64(is_table + (port_index * sizeof_ipc_entry_t));
  return port_addr;
}

#define OSDictionary_ItemCount(dict) rk32(dict+20)
#define OSDictionary_ItemBuffer(dict) rk64(dict+32)
#define OSDictionary_ItemKey(buffer, idx) rk64(buffer+16*idx)
#define OSDictionary_ItemValue(buffer, idx) rk64(buffer+16*idx+8)
                uint32_t SetObjectWithCharP = 8*31;
#define OSDictionary_SetItem(dict, str, val) {\
uint64_t s = kalloc(strlen(str)+1); kwrite(s, str, strlen(str)); \
kexecute(user_client, fake_client, rk64(rk64(dict)+SetObjectWithCharP), dict, s, val, 0, 0, 0, 0); \
            }
#define OSDictionary_SetItem2(dict, str, val) \
  kexecute(user_client, fake_client, rk64(rk64(dict)+SetObjectWithCharP), dict, str, val, 0, 0, 0, 0)
#define OSString_CStringPtr(str) rk64(str+0x10)

uint32_t OSArray_Merge_offset = (8*30);

// FIXME hardcoded offset!!
#define OSUnserializeXML_offset (0xfffffff0075192ac)

bool kexecute_lock = false;

uint64_t kexecute(mach_port_t user_client, uint64_t fake_client, uint64_t addr, uint64_t x0, uint64_t x1, uint64_t x2, uint64_t x3, uint64_t x4, uint64_t x5, uint64_t x6) {
    while (kexecute_lock == true){
      NSLog(@"Kexecute locked. Waiting for 10ms.");
      usleep(10000);
    }
    kexecute_lock = true;

    // When calling IOConnectTrapX, this makes a call to iokit_user_client_trap, which is the user->kernel call (MIG). This then calls IOUserClient::getTargetAndTrapForIndex
    // to get the trap struct (which contains an object and the function pointer itself). This function calls IOUserClient::getExternalTrapForIndex, which is expected to return a trap.
    // This jumps to our gadget, which returns +0x40 into our fake user_client, which we can modify. The function is then called on the object. But how C++ actually works is that the
    // function is called with the first arguement being the object (referenced as `this`). Because of that, the first argument of any function we call is the object, and everything else is passed
    // through like normal.

    // Because the gadget gets the trap at user_client+0x40, we have to overwrite the contents of it
    // We will pull a switch when doing so - retrieve the current contents, call the trap, put back the contents
    // (i'm not actually sure if the switch back is necessary but meh)

    uint64_t offx20 = rk64(fake_client+0x40);
    uint64_t offx28 = rk64(fake_client+0x48);
    wk64(fake_client+0x40, x0);
    wk64(fake_client+0x48, addr);
    uint64_t returnval = IOConnectTrap6(user_client, 0, (uint64_t)(x1), (uint64_t)(x2), (uint64_t)(x3), (uint64_t)(x4), (uint64_t)(x5), (uint64_t)(x6));
    wk64(fake_client+0x40, offx20);
    wk64(fake_client+0x48, offx28);
    kexecute_lock = false;
    return returnval;
}

int dumppid(int pd){
  int tries = 3;
  while (tries-- > 0) {
      uint64_t proc = rk64(find_allproc());
      while (proc) {
            uint32_t pid = rk32(proc + offsetof_p_pid);
            if (pid == pd) {
                uid_t p_uid = rk32(proc + offsetof_p_uid);
                gid_t p_gid = rk32(proc + offsetof_p_gid);
                uid_t p_ruid = rk32(proc + offsetof_p_ruid);
                gid_t p_rgid = rk32(proc + offsetof_p_rgid);

                uint64_t ucred = rk64(proc + offsetof_p_ucred);
                uid_t cr_uid = rk32(ucred + offsetof_ucred_cr_uid);
                uid_t cr_ruid = rk32(ucred + offsetof_ucred_cr_ruid);
                uid_t cr_svuid = rk32(ucred + offsetof_ucred_cr_svuid);

                NSLog(@"Found PID %d", pid);
                NSLog(@"UID: %d GID: %d RUID: %d RGID: %d", p_uid, p_gid, p_ruid, p_rgid);
                NSLog(@"CR_UID: %d CR_RUID: %d CR_SVUID: %d", cr_uid, cr_ruid, cr_svuid);
                return 0;
            }
            proc = rk64(proc);
      }
  }
}

// this should be good enough...
const char EXTRA_SANDBOX_READS[] = (
  "<plist version=\"1.0\"><array>"
    "<string>/bootstrap/</string>"
    "<string>/Library/</string>"
    "<string>/private/var/mobile/Library/Preferences/</string>"
  "</array></plist>");

int setcsflagsandplatformize(int pd){
  int tries = 3;
  while (tries-- > 0) {
      uint64_t proc = rk64(find_allproc());
      while (proc) {
          uint32_t pid = rk32(proc + offsetof_p_pid);
          if (pid == pd) {
              uint32_t csflags = rk32(proc + offsetof_p_csflags);
#if JAILBREAKDDEBUG
              NSLog(@"Previous CSFlags: 0x%x", csflags);
#endif
              csflags = (csflags | CS_PLATFORM_BINARY | CS_INSTALLER | CS_GET_TASK_ALLOW | CS_DEBUGGED) & ~(CS_RESTRICT | CS_HARD | CS_KILL);
#if JAILBREAKDDEBUG
              NSLog(@"New CSFlags: 0x%x", csflags);
#endif
              wk32(proc + offsetof_p_csflags, csflags);

              // task.t_flags & TF_PLATFORM
              uint64_t task = rk64(proc + offsetof_task);
              uint32_t t_flags = rk32(task + offsetof_t_flags);
#if JAILBREAKDDEBUG
              NSLog(@"Old t_flags: 0x%x", t_flags);
#endif
              t_flags |= TF_PLATFORM;
              wk32(task+offsetof_t_flags, t_flags);
#if JAILBREAKDDEBUG
              NSLog(@"New t_flags: 0x%x", t_flags);
#endif

              // AMFI entitlements
#if JAILBREAKDDEBUG
              NSLog(@"%@",@"AMFI:");
#endif
              uint64_t proc_ucred = rk64(proc+0x100);
              uint64_t amfi_entitlements = rk64(rk64(proc_ucred+0x78)+0x8);
#if JAILBREAKDDEBUG
              NSLog(@"%@",@"Setting Entitlements...");
#endif

              static uint64_t get_task_allow_cstrp = 0;
              static uint64_t cap_slv_cstrp = 0;
              static uint64_t exception_cstrp = 0;
              static uint64_t exception_payloadp = 0;
              if (!get_task_allow_cstrp) {
                NSLog(@"initializing our one-time kernel stuff!!");
                const char sp[] = "com.apple.security.exception.files.absolute-path.read-only\0get-task-allow\0com.apple.private.skip-library-validation";
                uint64_t s2_offset = strlen(sp) + 1;
                uint64_t s3_offset = strlen(sp + s2_offset) + 1;
                uint64_t s = kalloc(sizeof(sp));
                kwrite(s, sp, sizeof(sp));

                exception_cstrp = s;
                get_task_allow_cstrp = s + s2_offset;
                cap_slv_cstrp = get_task_allow_cstrp + s3_offset;

                NSLog(@"done setting strings...");

                // FIXME we're leaking this kalloc
                uint64_t her_xml = kalloc(sizeof(EXTRA_SANDBOX_READS));
                kwrite(her_xml, EXTRA_SANDBOX_READS, sizeof(EXTRA_SANDBOX_READS));

                // kexecute only returns the low bytes of the real value
                exception_payloadp = 0xffffffe000000000 | kexecute(user_client, fake_client, kernel_slide + OSUnserializeXML_offset, her_xml, 0, 0, 0, 0, 0, 0);
                NSLog(@"loaded our OSArray into kernel... at 0x%16llx", exception_payloadp);

                // char my_errors[1024];
                // kread(OSString_CStringPtr(errors + 8), my_errors, 1024 - 8);
                // NSLog(@"OSUnserializeXML error: %s", my_errors);
              }

              NSLog(@"injecting entitlements now");
              OSDictionary_SetItem2(amfi_entitlements, get_task_allow_cstrp, find_OSBoolean_True());
              OSDictionary_SetItem2(amfi_entitlements, cap_slv_cstrp, find_OSBoolean_True());

              int found = 0;
              for (int idx = 0; idx < OSDictionary_ItemCount(amfi_entitlements); idx++) {
                  uint64_t key = OSDictionary_ItemKey(OSDictionary_ItemBuffer(amfi_entitlements), idx);
                  uint64_t keyOSStr = OSString_CStringPtr(key);

                  // OSString getLength goes like...
                  // fffffff00751561c         ldr        w8, [x0, #0xc]
                  // fffffff007515620         lsr        w8, w8, #0xe
                  // fffffff007515624         sub        w0, w8, #0x1
                  // fffffff007515628         ret

                  // length != strlen(com.apple.security.blah...)
                  size_t length = ((rk32(key + 0xc) >> 0xe) & 0x3ffff) /* - 1 */;
                  if (length != get_task_allow_cstrp - exception_cstrp) {
                    continue;
                  }

                  char s[get_task_allow_cstrp - exception_cstrp];
                  kread(keyOSStr, s, length);
                  NSLog(@"Entitlement: %s", s);

                  if (!strcmp(s, "com.apple.security.exception.files.absolute-path.read-only")) {
                    found = idx;
                    break;
                  }
              }

              if (found) {
                uint64_t arrayp = OSDictionary_ItemValue(OSDictionary_ItemBuffer(amfi_entitlements), found);
                if (arrayp == exception_payloadp) {
                  NSLog(@"extending our exception array, wtf?? reinjecting?");
                } else {
                  // this code doesn't work
#if 0
                  NSLog(@"extending array %10llx, current exc count %u", arrayp, rk32(arrayp + 0x14));
                  NSLog(@"wtf are we calling?? %10llx", rk64(rk64(arrayp)+OSArray_Merge_offset));
                  kexecute(user_client, fake_client, rk64(rk64(arrayp)+OSArray_Merge_offset), arrayp, exception_payloadp, 0, 0, 0, 0, 0);
                  NSLog(@"called merge, current exc count %u", arrayp, rk32(arrayp + 0x14));
#endif
                }
              } else {
                NSLog(@"no previous exception entitlement");
                OSDictionary_SetItem2(amfi_entitlements, exception_cstrp, exception_payloadp);
              }

              NSLog(@"Set Entitlements on PID %d", pd);

              uint64_t textvp = rk64(proc + offsetof_p_textvp); //vnode of executable
              off_t textoff = rk64(proc + offsetof_p_textoff);

#if JAILBREAKDDEBUG
              NSLog(@"\t__TEXT at 0x%llx. Offset: 0x%llx", textvp, textoff);
#endif
              if (textvp != 0){
                uint32_t vnode_type_tag = rk32(textvp + offsetof_v_type);
                uint16_t vnode_type = vnode_type_tag & 0xffff;
                uint16_t vnode_tag = (vnode_type_tag >> 16);
#if JAILBREAKDDEBUG
                NSLog(@"\tVNode Type: 0x%x. Tag: 0x%x.", vnode_type, vnode_tag);
#endif

                if (vnode_type == 1){
                    uint64_t ubcinfo = rk64(textvp + offsetof_v_ubcinfo);
#if JAILBREAKDDEBUG
                    NSLog(@"\t\tUBCInfo at 0x%llx.\n", ubcinfo);
#endif

                    uint64_t csblobs = rk64(ubcinfo + offsetof_ubcinfo_csblobs);
                    while (csblobs != 0){
#if JAILBREAKDDEBUG
                        NSLog(@"\t\t\tCSBlobs at 0x%llx.", csblobs);
#endif

                        cpu_type_t csblob_cputype = rk32(csblobs + offsetof_csb_cputype);
                        unsigned int csblob_flags = rk32(csblobs + offsetof_csb_flags);
                        off_t csb_base_offset = rk64(csblobs + offsetof_csb_base_offset);
                        uint64_t csb_entitlements = rk64(csblobs + offsetof_csb_entitlements_offset);
                        unsigned int csb_signer_type = rk32(csblobs + offsetof_csb_signer_type);
                        unsigned int csb_platform_binary = rk32(csblobs + offsetof_csb_platform_binary);
                        unsigned int csb_platform_path = rk32(csblobs + offsetof_csb_platform_path);

#if JAILBREAKDDEBUG
                        NSLog(@"\t\t\tCSBlob CPU Type: 0x%x. Flags: 0x%x. Offset: 0x%llx", csblob_cputype, csblob_flags, csb_base_offset);
                        NSLog(@"\t\t\tCSBlob Signer Type: 0x%x. Platform Binary: %d Path: %d", csb_signer_type, csb_platform_binary, csb_platform_path);
#endif
                        wk32(csblobs + offsetof_csb_platform_binary, 1);

                        csb_platform_binary = rk32(csblobs + offsetof_csb_platform_binary);
#if JAILBREAKDDEBUG
                        NSLog(@"\t\t\tCSBlob Signer Type: 0x%x. Platform Binary: %d Path: %d", csb_signer_type, csb_platform_binary, csb_platform_path);

                        NSLog(@"\t\t\t\tEntitlements at 0x%llx.\n", csb_entitlements);
#endif
                        csblobs = rk64(csblobs);
                    }
                }
              }

              /*for (int idx = 0; idx < OSDictionary_ItemCount(amfi_entitlements); idx++) {
                  uint64_t key = OSDictionary_ItemKey(OSDictionary_ItemBuffer(amfi_entitlements), idx);
                  uint64_t keyOSStr = OSString_CStringPtr(key);
                  size_t length = kexecute(user_client, fake_client, 0xFFFFFFF00709BDE0+kernel_slide, keyOSStr, 0, 0, 0, 0, 0, 0); //strlen
                  char* s = (char*)calloc(length+1, 1);
                  kread(keyOSStr, s, length);
                  NSLog(@"Entitlement: %s", s);
                  free(s);
              }*/

              return 0;
          }
          proc = rk64(proc);
      }
  }
  NSLog(@"Unable to find PID %d to entitle!", pd);
  return 0;
}
