#!/usr/bin/env python3
"""Send the MEP-A1 targetPortIndex in ES10c Enable/DisableProfile, with a fallback.

warhol's eUICC slot is reported by the modem as MEP_A1 (dumpsys: `mSupportedMepMode=MEP_A1,
mPortIdxToPhoneId={0=1, 1=-1}`), and AOSP's own LPA path adds a third field to
EnableProfileRequest in exactly that case:

    frameworks/opt/telephony/.../uicc/euicc/EuiccPort.java:315
        if (mSupportedMepMode.isMepA1Mode()) {
            builder.addChildAsInteger(Tags.TAG_CTX_2,
                    PortUtils.convertToHalPortIndex(mSupportedMepMode, super.getPortIdx()));
        }

    PortUtils.convertToHalPortIndex(): "In case of MEP-A1 and MEP-A2, profiles are selected
    on eSIM Ports 1 and higher" -- so the platform port 0 the LPA opened its channel on
    becomes target port 1.

lpac never emits that field, so every EnableProfile it builds is the pre-MEP two-field form:

    81E2910014 BF3111 A00C 5A0A <iccid> 810100            -> 6A80
    81E291001A BF3117 A012 4F10 <isdpAid> 810100          -> 6A80

both refused, for both refresh flags, while BF2D/BF3E/BF22/BF29 (including the *write*
SetNickname) all answer 9000 on the same logical channel -- i.e. the channel, the ISD-R
selection and the ES10x framing are all fine and only BF31 is rejected.

This adds an optional targetPortIndex to the two commands that take one. -1 keeps the
exact bytes lpac emits today, so a pre-MEP eUICC is unaffected; the Kotlin side tries -1
first and only retries with a port if the card refuses. That ordering matters because
OpenEUICC cannot see the MEP *mode* -- UiccSlotInfo only exposes
isMultipleEnabledProfilesSupported, not A1 vs A2 vs B -- and only A1 wants this field.

Idempotent: re-running is a no-op. Both packages/apps/OpenEUICC and its lpac submodule are
synced, so repo sync reverts this.
"""
import sys

BASE = ("/run/media/local/4TB/warhol-los-24/src/packages/apps/OpenEUICC/libs/lpac-jni/src/main/")
MARKER = "targetPortIndex"

EDITS = []

# ---- 1. es10c.h: the two prototypes -----------------------------------------------
EDITS.append((
    "jni/lpac/euicc/es10c.h",
    "int es10c_enable_profile(struct euicc_ctx *ctx, const char *id, uint8_t refreshFlag);\n"
    "int es10c_disable_profile(struct euicc_ctx *ctx, const char *id, uint8_t refreshFlag);\n",
    "/* targetPortIndex < 0 omits the field entirely (pre-MEP form). */\n"
    "int es10c_enable_profile(struct euicc_ctx *ctx, const char *id, uint8_t refreshFlag,\n"
    "                         int targetPortIndex);\n"
    "int es10c_disable_profile(struct euicc_ctx *ctx, const char *id, uint8_t refreshFlag,\n"
    "                          int targetPortIndex);\n",
))

# ---- 2. es10c.c: the builder ------------------------------------------------------
EDITS.append((
    "jni/lpac/euicc/es10c.c",
    "static int es10c_enable_disable_delete_profile(struct euicc_ctx *ctx, uint16_t op_tag, const char *str_id,\n"
    "                                               uint8_t refreshFlag) {\n"
    "    int fret = 0;\n"
    "    uint8_t id[16];\n"
    "    int id_len;\n"
    "    struct euicc_derutil_node n_request, n_choicer, n_profileIdentifierChoice, n_refreshFlag;\n",

    "static int es10c_enable_disable_delete_profile(struct euicc_ctx *ctx, uint16_t op_tag, const char *str_id,\n"
    "                                               uint8_t refreshFlag, int targetPortIndex) {\n"
    "    int fret = 0;\n"
    "    uint8_t id[16];\n"
    "    int id_len;\n"
    "    uint8_t targetPort;\n"
    "    struct euicc_derutil_node n_request, n_choicer, n_profileIdentifierChoice, n_refreshFlag,\n"
    "        n_targetPortIndex;\n",
))

EDITS.append((
    "jni/lpac/euicc/es10c.c",
    "    memset(&n_refreshFlag, 0, sizeof(n_refreshFlag));\n",
    "    memset(&n_refreshFlag, 0, sizeof(n_refreshFlag));\n"
    "    memset(&n_targetPortIndex, 0, sizeof(n_targetPortIndex));\n",
))

EDITS.append((
    "jni/lpac/euicc/es10c.c",
    "        n_choicer.tag = 0xA0;\n"
    "        n_choicer.pack.child = &n_profileIdentifierChoice;\n"
    "        n_choicer.pack.next = &n_refreshFlag;\n"
    "\n"
    "        n_request.pack.child = &n_choicer;\n",

    "        n_choicer.tag = 0xA0;\n"
    "        n_choicer.pack.child = &n_profileIdentifierChoice;\n"
    "        n_choicer.pack.next = &n_refreshFlag;\n"
    "\n"
    "        /* targetPortIndex [2], SGP.22 v3 #MEP. AOSP only sends it for MEP-A1\n"
    "         * (EuiccPort.java: if (mSupportedMepMode.isMepA1Mode())), where the port the\n"
    "         * ISD-P is enabled on is the LPA's platform port index + 1. */\n"
    "        if (targetPortIndex >= 0) {\n"
    "            targetPort = (uint8_t)targetPortIndex;\n"
    "            n_targetPortIndex.tag = 0x82;\n"
    "            n_targetPortIndex.length = 1;\n"
    "            n_targetPortIndex.value = &targetPort;\n"
    "            n_refreshFlag.pack.next = &n_targetPortIndex;\n"
    "        }\n"
    "\n"
    "        n_request.pack.child = &n_choicer;\n",
))

EDITS.append((
    "jni/lpac/euicc/es10c.c",
    "int es10c_enable_profile(struct euicc_ctx *ctx, const char *id, uint8_t refreshFlag) {\n"
    "    if (refreshFlag) {\n"
    "        refreshFlag = 0xFF;\n"
    "    } else {\n"
    "        refreshFlag = 0x80;\n"
    "    }\n"
    "    return es10c_enable_disable_delete_profile(ctx, 0xBF31, id, refreshFlag);\n"
    "}\n"
    "\n"
    "int es10c_disable_profile(struct euicc_ctx *ctx, const char *id, uint8_t refreshFlag) {\n"
    "    if (refreshFlag) {\n"
    "        refreshFlag = 0xFF;\n"
    "    } else {\n"
    "        refreshFlag = 0x80;\n"
    "    }\n"
    "    return es10c_enable_disable_delete_profile(ctx, 0xBF32, id, refreshFlag);\n"
    "}\n"
    "\n"
    "int es10c_delete_profile(struct euicc_ctx *ctx, const char *id) {\n"
    "    return es10c_enable_disable_delete_profile(ctx, 0xBF33, id, 0);\n"
    "}\n",

    "int es10c_enable_profile(struct euicc_ctx *ctx, const char *id, uint8_t refreshFlag,\n"
    "                         int targetPortIndex) {\n"
    "    if (refreshFlag) {\n"
    "        refreshFlag = 0xFF;\n"
    "    } else {\n"
    "        refreshFlag = 0x80;\n"
    "    }\n"
    "    return es10c_enable_disable_delete_profile(ctx, 0xBF31, id, refreshFlag, targetPortIndex);\n"
    "}\n"
    "\n"
    "int es10c_disable_profile(struct euicc_ctx *ctx, const char *id, uint8_t refreshFlag,\n"
    "                          int targetPortIndex) {\n"
    "    if (refreshFlag) {\n"
    "        refreshFlag = 0xFF;\n"
    "    } else {\n"
    "        refreshFlag = 0x80;\n"
    "    }\n"
    "    return es10c_enable_disable_delete_profile(ctx, 0xBF32, id, refreshFlag, targetPortIndex);\n"
    "}\n"
    "\n"
    "int es10c_delete_profile(struct euicc_ctx *ctx, const char *id) {\n"
    "    /* DeleteProfileRequest has no refreshFlag and no targetPortIndex. */\n"
    "    return es10c_enable_disable_delete_profile(ctx, 0xBF33, id, 0, -1);\n"
    "}\n",
))

# ---- 3. lpac-jni.c ----------------------------------------------------------------
EDITS.append((
    "jni/lpac-jni/lpac-jni.c",
    "Java_net_typeblog_lpac_1jni_LpacJni_es10cEnableProfile(JNIEnv *env, jobject thiz, jlong handle,\n"
    "                                                       jstring iccid, jboolean refresh) {\n"
    "    struct euicc_ctx *ctx = (struct euicc_ctx *) handle;\n"
    "    const char *_iccid = NULL;\n"
    "    int ret;\n"
    "\n"
    "    _iccid = (*env)->GetStringUTFChars(env, iccid, NULL);\n"
    "    ret = es10c_enable_profile(ctx, _iccid, refresh ? 1 : 0);\n",

    "Java_net_typeblog_lpac_1jni_LpacJni_es10cEnableProfile(JNIEnv *env, jobject thiz, jlong handle,\n"
    "                                                       jstring iccid, jboolean refresh,\n"
    "                                                       jint targetPortIndex) {\n"
    "    struct euicc_ctx *ctx = (struct euicc_ctx *) handle;\n"
    "    const char *_iccid = NULL;\n"
    "    int ret;\n"
    "\n"
    "    _iccid = (*env)->GetStringUTFChars(env, iccid, NULL);\n"
    "    ret = es10c_enable_profile(ctx, _iccid, refresh ? 1 : 0, targetPortIndex);\n",
))

EDITS.append((
    "jni/lpac-jni/lpac-jni.c",
    "Java_net_typeblog_lpac_1jni_LpacJni_es10cDisableProfile(JNIEnv *env, jobject thiz, jlong handle,\n"
    "                                                        jstring iccid, jboolean refresh) {\n"
    "    struct euicc_ctx *ctx = (struct euicc_ctx *) handle;\n"
    "    const char *_iccid = NULL;\n"
    "    int ret;\n"
    "\n"
    "    _iccid = (*env)->GetStringUTFChars(env, iccid, NULL);\n"
    "    ret = es10c_disable_profile(ctx, _iccid, refresh ? 1 : 0);\n",

    "Java_net_typeblog_lpac_1jni_LpacJni_es10cDisableProfile(JNIEnv *env, jobject thiz, jlong handle,\n"
    "                                                        jstring iccid, jboolean refresh,\n"
    "                                                        jint targetPortIndex) {\n"
    "    struct euicc_ctx *ctx = (struct euicc_ctx *) handle;\n"
    "    const char *_iccid = NULL;\n"
    "    int ret;\n"
    "\n"
    "    _iccid = (*env)->GetStringUTFChars(env, iccid, NULL);\n"
    "    ret = es10c_disable_profile(ctx, _iccid, refresh ? 1 : 0, targetPortIndex);\n",
))

# ---- 4. LpacJni.kt ----------------------------------------------------------------
EDITS.append((
    "java/net/typeblog/lpac_jni/LpacJni.kt",
    "    external fun es10cEnableProfile(handle: Long, iccid: String, refresh: Boolean): Int\n"
    "    external fun es10cDisableProfile(handle: Long, iccid: String, refresh: Boolean): Int\n",
    "    // targetPortIndex < 0 omits the SGP.22 v3 targetPortIndex field (pre-MEP form)\n"
    "    external fun es10cEnableProfile(\n"
    "        handle: Long, iccid: String, refresh: Boolean, targetPortIndex: Int\n"
    "    ): Int\n"
    "    external fun es10cDisableProfile(\n"
    "        handle: Long, iccid: String, refresh: Boolean, targetPortIndex: Int\n"
    "    ): Int\n",
))

# ---- 5. LocalProfileAssistantImpl.kt: the fallback --------------------------------
EDITS.append((
    "java/net/typeblog/lpac_jni/impl/LocalProfileAssistantImpl.kt",
    "    override fun enableProfile(iccid: String, refresh: Boolean): Boolean = lock.withLock {\n"
    "        LpacJni.es10cEnableProfile(contextHandle, iccid, refresh) == 0\n"
    "    }\n"
    "\n"
    "    override fun disableProfile(iccid: String, refresh: Boolean): Boolean = lock.withLock {\n"
    "        LpacJni.es10cDisableProfile(contextHandle, iccid, refresh) == 0\n"
    "    }\n",

    "    // A MEP-A1 eUICC refuses ES10c Enable/DisableProfile unless the request names the\n"
    "    // port the profile is to be enabled on (targetPortIndex [2], SGP.22 v3 #MEP); warhol's\n"
    "    // answers 6A80 to the pre-MEP two-field form for every refresh flag and for both the\n"
    "    // ICCID and the ISD-P AID. AOSP sends the field only for MEP-A1 (EuiccPort.java:315)\n"
    "    // and derives it as platform port index + 1 (PortUtils.convertToHalPortIndex), but an\n"
    "    // app cannot see the MEP *mode* -- UiccSlotInfo exposes only\n"
    "    // isMultipleEnabledProfilesSupported -- so try the standard form first and fall back.\n"
    "    // On a pre-MEP eUICC the first attempt succeeds and the fallback never runs.\n"
    "    private val targetPortFallback = listOf(-1, 1, 2)\n"
    "\n"
    "    override fun enableProfile(iccid: String, refresh: Boolean): Boolean = lock.withLock {\n"
    "        targetPortFallback.any { port ->\n"
    "            LpacJni.es10cEnableProfile(contextHandle, iccid, refresh, port) == 0\n"
    "        }\n"
    "    }\n"
    "\n"
    "    override fun disableProfile(iccid: String, refresh: Boolean): Boolean = lock.withLock {\n"
    "        targetPortFallback.any { port ->\n"
    "            LpacJni.es10cDisableProfile(contextHandle, iccid, refresh, port) == 0\n"
    "        }\n"
    "    }\n",
))


def main():
    files = {}
    for rel, old, new in EDITS:
        p = BASE + rel
        if p not in files:
            files[p] = open(p, encoding="utf-8").read()
        s = files[p]
        if new in s:
            continue          # this hunk already applied
        if s.count(old) != 1:
            print("ABORT: %s anchor matched %d times, expected 1" % (rel, s.count(old)))
            return 1
        files[p] = s.replace(old, new, 1)

    changed = 0
    for p, s in files.items():
        cur = open(p, encoding="utf-8").read()
        if cur != s:
            open(p, "w", encoding="utf-8").write(s)
            changed += 1
    if changed == 0:
        print("already patched")
    else:
        print("patched %d file(s): ES10c Enable/DisableProfile can carry targetPortIndex" % changed)
    return 0


sys.exit(main())
