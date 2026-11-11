// One exported function, built three times with different names and values (build_probe.sh):
//   Probe.framework      probe_answer() = 42   loaded from the app bundle (baseline)
//   GameProbe.framework  game_answer()  = 43   copied by the app from its bundle into Documents, then loaded there
//   PushProbe.framework  push_answer()  = 46   built for the computer to sign and push into Documents/Inbox
//   AdhocProbe           adhoc_answer() = 45   negative control: ad-hoc signature only, must be refused
#ifndef ANSWER_FN
#error ANSWER_FN not set
#endif
__attribute__((visibility("default"))) int ANSWER_FN(void) { return ANSWER; }
