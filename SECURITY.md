# Security

## Supported versions

Only the latest release gets security fixes. Meowse updates itself, and Settings → Updates shows which version you have.

## Reporting a vulnerability

Please report it privately, not in a public issue: open a [private security advisory](https://github.com/salvcy/meowse/security/advisories/new) on this repository. Only you and the maintainer can see it.

Include what you found, the steps to reproduce it, the Meowse and macOS versions, and what an attacker could do with it. You'll get a reply within a few days, and a fix ships as a new release as soon as it's ready. You're credited in the advisory unless you'd rather not be.

## What's in scope

- The Meowse app and its Settings window
- The in-app updater: how it downloads, verifies and installs a release
- The Keep Awake helper that keeps a MacBook running with its lid closed
- Release signing: every `Meowse.zip` is signed with the developer's Apple Developer ID and notarized by Apple

## Checking a download

Before it installs an update, Meowse checks that the new copy is signed by the same developer as the one you're running. To check a copy yourself:

```sh
spctl -a -vv /Applications/Meowse.app
```

It should say `accepted` and `source=Notarized Developer ID`.
