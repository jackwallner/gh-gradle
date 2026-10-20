# gh-gradle

Runs Gradle builds and tests of the Android ports (the `android/` folder) of
Jack's public app repos on free GitHub-hosted Linux runners, so the MacBook Air
and the Intel fleet machines do not have to.

Use it through `~/bin/gh-gradle` (`gh-gradle testDebugUnitTest assembleDebug`,
`gh-gradle ls`); it pushes a snapshot of the working tree to
`refs/gh-gradle/<id>` in the app repo, dispatches `gradle.yml` here, and
downloads the `result` artifact. `--emulator <api>` runs the tasks against a
KVM emulator (reactivecircus/android-emulator-runner) for connected tests.
Logs and artifacts here are public: never pass secrets as inputs, and never
run signing, release or upload tasks here (gh-gradle refuses them).
