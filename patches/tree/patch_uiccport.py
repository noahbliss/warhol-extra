#!/usr/bin/env python3
"""Patch UiccPort.iccTransmitApduLogicalChannel to flag ES10 commands.

AOSP's own eUICC stack always sets isEs10 = true (ApduCommand.java:63), and the flag
reaches the radio HAL as msg.isEs10 -- it is how the modem is told to route an APDU to
the ISD-R rather than into the enabled profile's context. That matters on a MEP eUICC,
and warhol's is MEP_A1. But PhoneInterfaceManager (CMD_TRANSMIT_APDU_LOGICAL_CHANNEL)
calls the deprecated 8-arg UiccPort wrapper, which hardcodes false -- so every
third-party privileged LPA's ES10 traffic is mislabeled and this modem answers
6881 "logical channel not supported" on a channel that opened with SW 9000.

Derive the flag from the AID the channel was actually opened against; UiccPort already
keeps that in OpenLogicalChannelRecord.mRequest.aid.
Idempotent: re-running is a no-op.
"""
import sys

P = ("/run/media/local/4TB/warhol-los-24/src/frameworks/opt/telephony/src/java/"
     "com/android/internal/telephony/uicc/UiccPort.java")

MARKER = "ISDR_AID_PREFIX"

OLD = """    @Deprecated
    public void iccTransmitApduLogicalChannel(int channel, int cla, int command,
            int p1, int p2, int p3, String data, Message response) {
        if (mUiccProfile != null) {
            mUiccProfile.iccTransmitApduLogicalChannel(channel, cla, command, p1, p2, p3,
                    data, false /*isEs10Command*/, response);
        } else {
            loge("iccTransmitApduLogicalChannel Failed!");
        }
    }
"""

NEW = """    @Deprecated
    public void iccTransmitApduLogicalChannel(int channel, int cla, int command,
            int p1, int p2, int p3, String data, Message response) {
        if (mUiccProfile != null) {
            mUiccProfile.iccTransmitApduLogicalChannel(channel, cla, command, p1, p2, p3,
                    data, isEs10Channel(channel), response);
        } else {
            loge("iccTransmitApduLogicalChannel Failed!");
        }
    }

    /**
     * SGP.22 ISD-R AID prefix. The full AID is vendor-suffixed (warhol's eUICC reports
     * A0000005591010FFFFFFFF8900000100), so match on the registered prefix only.
     */
    private static final String ISDR_AID_PREFIX = "A0000005591010";

    /**
     * True when {@code channel} was opened against the ISD-R, i.e. APDUs on it are ES10
     * commands.
     *
     * <p>This flag is plumbed to the radio HAL as {@code msg.isEs10} and tells the modem
     * to route the APDU to the ISD-R instead of the enabled profile's context. On a
     * multiple-enabled-profile (MEP) eUICC that distinction is load-bearing: without it
     * this device's modem rejects a correctly formed ES10 STORE DATA with SW 6881
     * ("logical channel not supported") on a channel that opened with SW 9000 and
     * returned a valid ISD-R FCI.
     *
     * <p>AOSP's in-tree eUICC stack hardcodes {@code isEs10 = true}
     * (ApduCommand.java), but the deprecated wrapper above -- the path
     * PhoneInterfaceManager uses for every third-party
     * {@code iccTransmitApduLogicalChannelByPort} caller, i.e. any privileged in-ROM
     * LPA -- hardcoded {@code false}. Derive it from the AID instead of guessing.
     */
    private boolean isEs10Channel(int channel) {
        OpenLogicalChannelRecord record = getOpenLogicalChannelRecord(channel);
        if (record == null || record.mRequest == null || record.mRequest.aid == null) {
            return false;
        }
        return record.mRequest.aid.regionMatches(
                true /*ignoreCase*/, 0, ISDR_AID_PREFIX, 0, ISDR_AID_PREFIX.length());
    }
"""

s = open(P, encoding="utf-8").read()

if MARKER in s:
    print("already patched: %s" % MARKER)
    sys.exit(0)

n = s.count(OLD)
if n != 1:
    print("ABORT: anchor matched %d times, expected 1 -- not patching" % n)
    sys.exit(1)

open(P, "w", encoding="utf-8").write(s.replace(OLD, NEW, 1))
print("patched UiccPort.java: isEs10Command now derived from the channel AID")
