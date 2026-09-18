#!/usr/bin/env python3
"""
warhol eSIM: fix the OpenEUICC/lpac-jni use-after-free that produces the benign
but user-visible "Can't switch SIMs / Something went wrong" error when enabling
an eSIM.

Root cause: LocalProfileAssistantImpl.valid checks `finalized` OUTSIDE the object
lock, then calls eID (native es10cGetEid) under the lock. If another thread runs
close() -> LpacJni.destroyContext() (which free()s the native context) in the
window between the check and the native call, es10cGetEid runs on a freed context.
lpac then transmits an APDU through a zero-filled apdu_interface global ref, and
apdu_interface_transmit()'s CallObjectMethod() dereferences NULL -> SIGSEGV kills
the whole LPA process. Settings' SwitchToEuiccSubscriptionSidecar sees the dead
callback and shows sim_action_enable_sim_fail_* even though the profile enabled.

Two fixes (defense in depth):
  1) Kotlin: evaluate the whole `valid` getter under the (reentrant) lock so the
     finalized check and the native eID/euiccInfo2 reads are one critical section.
  2) C: guard apdu_interface_transmit against a null interface / null jmethodID
     (turns a fatal SIGSEGV into a normal lpac error) and against a null return
     array (a separate latent crash in GetArrayLength).

Idempotent; hooked into patch_tree() in remote-build.sh. packages/apps/OpenEUICC
and the lpac submodule are synced projects, so repo sync reverts this.
"""
import os
import sys

ROOT = os.environ.get("WARHOL_ROOT") or "/run/media/local/4TB/warhol-los-24"
OE = os.path.join(ROOT, "src/packages/apps/OpenEUICC")

KT = os.path.join(
    OE, "libs/lpac-jni/src/main/java/net/typeblog/lpac_jni/impl/LocalProfileAssistantImpl.kt"
)
CW = os.path.join(OE, "libs/lpac-jni/src/main/jni/lpac-jni/interface-wrapper.c")

KT_OLD = """    override val valid: Boolean
        get() = !finalized && apduInterface.valid && try {
            // If we can read both eID and euiccInfo2 properly, we are likely looking at
            // a valid LocalProfileAssistant
            eID
            euiccInfo2!!
            true
        } catch (e: Exception) {
            false
        }"""

KT_NEW = """    override val valid: Boolean
        // Hold the lock across the finalized check AND the native reads. Checking
        // finalized outside the lock raced close()/destroyContext() and used a
        // freed native context (SIGSEGV). lock is reentrant, so eID/euiccInfo2
        // re-acquire it fine.
        get() = lock.withLock {
            !finalized && apduInterface.valid && try {
                // If we can read both eID and euiccInfo2 properly, we are likely
                // looking at a valid LocalProfileAssistant
                eID
                euiccInfo2!!
                true
            } catch (e: Exception) {
                false
            }
        }"""

KT_MARKER = "finalized check AND the native reads"

C_OLD = """    const int logic_channel = LPAC_JNI_CTX(ctx)->logical_channel_id;
    LPAC_JNI_SETUP_ENV;
    jbyteArray txArr = (*env)->NewByteArray(env, tx_len);
    (*env)->SetByteArrayRegion(env, txArr, 0, tx_len, (const jbyte *) tx);
    jbyteArray ret = (jbyteArray) (*env)->CallObjectMethod(
            env, LPAC_JNI_CTX(ctx)->apdu_interface,
            method_apdu_transmit, logic_channel, txArr
    );
    LPAC_JNI_EXCEPTION_RETURN;
    *rx_len = (*env)->GetArrayLength(env, ret);"""

C_NEW = """    const int logic_channel = LPAC_JNI_CTX(ctx)->logical_channel_id;
    LPAC_JNI_SETUP_ENV;
    /* Guard a torn-down context (use-after-close) or a null interface: calling
     * CallObjectMethod() on a null apdu_interface would SIGSEGV the whole LPA
     * process. Fail the APDU instead so lpac reports the error normally. */
    if (LPAC_JNI_CTX(ctx)->apdu_interface == NULL || method_apdu_transmit == NULL) {
        return -1;
    }
    jbyteArray txArr = (*env)->NewByteArray(env, tx_len);
    (*env)->SetByteArrayRegion(env, txArr, 0, tx_len, (const jbyte *) tx);
    jbyteArray ret = (jbyteArray) (*env)->CallObjectMethod(
            env, LPAC_JNI_CTX(ctx)->apdu_interface,
            method_apdu_transmit, logic_channel, txArr
    );
    LPAC_JNI_EXCEPTION_RETURN;
    /* A null return (transmit gave back null with no pending exception) would
     * crash GetArrayLength below. */
    if (ret == NULL) {
        return -1;
    }
    *rx_len = (*env)->GetArrayLength(env, ret);"""

C_MARKER = "apdu_interface == NULL || method_apdu_transmit == NULL"


def patch(path, old, new, marker):
    if not os.path.isfile(path):
        print("patch_esim_uaf: MISSING %s" % path, file=sys.stderr)
        return False
    with open(path) as f:
        s = f.read()
    if marker in s:
        print("patch_esim_uaf: already applied (%s)" % os.path.basename(path))
        return True
    if old not in s:
        print("patch_esim_uaf: FAILED to match in %s" % path, file=sys.stderr)
        return False
    s = s.replace(old, new, 1)
    with open(path, "w") as f:
        f.write(s)
    print("patch_esim_uaf: patched %s" % os.path.basename(path))
    return True


ok = True
ok &= patch(KT, KT_OLD, KT_NEW, KT_MARKER)
ok &= patch(CW, C_OLD, C_NEW, C_MARKER)
sys.exit(0 if ok else 1)
