# Holdfast

Locks apps and websites on your Mac for a set time. The lock survives quitting the app and restarting the Mac.
The only way out early is typing a long random passage (10,000 words by default).

## Build and run

    ./build.sh
    open build/Holdfast.app

Needs the Xcode Command Line Tools. Drag `build/Holdfast.app` to `/Applications` if you want to keep it there.

On first launch, click **Install Helper** and enter your Mac administrator password in the macOS prompt. This is a one-time step.

## How it works

- `Sources/App` is the SwiftUI app: choose apps, websites, duration and challenge length.
- `Sources/Enforcer` is a background helper that macOS starts at boot and restarts if it is killed. While a lock is active it
  closes locked apps as soon as they open (matched by bundle identifier, so renaming or moving an app does not help) and
  redirects locked sites to nowhere in `/etc/hosts`, rewriting the entries if they are removed.
- The countdown uses a clock that ignores changes to the system date and time.
- A running lock can be made longer, never shorter.

## Limits

- Website locking works by hostname. Restart your browser after starting a lock so open tabs and cached connections drop.
  iCloud Private Relay and VPN browser extensions can bypass it.
- Someone with the administrator password and a terminal can still remove the helper by hand. Holdfast makes that
  inconvenient, not impossible.

## Remove

With no lock active, use the **Helper running** menu in the app and choose **Remove background helper…**.
Logs are in `/Library/Logs/Holdfast.log`.
