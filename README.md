<p align="center">
  <img src="docs/images/app-icon.png" width="128" height="128" alt="JottaFS app icon">
</p>

<h1 align="center">JottaFS</h1>

<p align="center">
  Use your Jottacloud files in Finder on your Mac, as a disk.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-27%2B-000000?logo=apple&logoColor=white" alt="macOS 27 or later">
  <img src="https://img.shields.io/badge/Swift-6.1-F05138?logo=swift&logoColor=white" alt="Swift 6.1">
  <img src="https://img.shields.io/badge/license-MIT-blue" alt="MIT license">
</p>

JottaFS is a macOS app and file system extension. It connects to your
Jottacloud account and shows one Jottacloud location in Finder as a disk.
You can open, copy, change, move and delete files on this disk. JottaFS sends
the changes to Jottacloud.

<p align="center">
  <a href="https://github.com/thomas-alrek/JottaFS/releases/latest">
    <img src="https://img.shields.io/github/v/release/thomas-alrek/JottaFS?label=Download&logo=apple&logoColor=white&color=8A5CF6&style=for-the-badge" alt="Download the latest version of JottaFS">
  </a>
  <br>
  <a href="https://github.com/thomas-alrek/JottaFS/releases/latest">Download the latest version (.dmg)</a>
</p>

JottaFS uses Apple FSKit. It does not use macFUSE or a kernel extension.

> [!IMPORTANT]
> JottaFS is not an official Jottacloud product. Jottacloud AS does not make,
> support or approve it. JottaFS uses Jottacloud interfaces that do not have
> public documentation. These interfaces can change at any time.

## Screenshots

<p align="center">
  <img src="docs/images/screenshot-sign-in.png" width="400" alt="The JottaFS sign-in window with the Sign In with Jottacloud button">
  &nbsp;
  <img src="docs/images/screenshot-locations.png" width="340" alt="The JottaFS window with the list of Jottacloud locations to mount">
</p>

<p align="center">
  <img src="docs/images/screenshot-finder.png" width="760" alt="Finder with the Jottacloud location Archive mounted as a disk, in the sidebar and next to Macintosh HD">
  <br>
  <em>The mounted location in Finder, as a disk next to Macintosh HD.</em>
</p>

## Contents

- [Features](#features)
- [Requirements](#requirements)
- [Install](#install)
- [Use JottaFS](#use-jottafs)
- [The Trash](#the-trash)
- [Limits](#limits)
- [Troubleshooting](#troubleshooting)
- [Privacy and security](#privacy-and-security)
- [How JottaFS works](#how-jottafs-works)
- [Development](#development)
- [Documentation](#documentation)
- [License](#license)

## Features

- **Sign in with your browser.** You sign in on jottacloud.com. JottaFS does
  not see your password.
- **Sign in with a personal login token.** Use this method if you do not want
  to sign in with your browser.
- **Mount locations as disks.** Select Archive, Sync, Shared, Photos or a
  folder from a computer backup. Each location shows in Finder as a disk
  with the same name. You can mount more than one location at the same time.
- **Read and write files.** Open, copy, change, rename, move and delete files
  and folders.
- **Upload progress in Finder.** The file icon shows a progress bar during the
  upload. A Finder copy is complete only when the upload is complete.
- **Resume uploads.** If the network connection stops during an upload,
  JottaFS tries again and continues from the last saved part.
- **Trash.** Move to Trash, Put Back and Empty Trash work with the Jottacloud
  trash. Refer to [The Trash](#the-trash).
- **Mount at login.** JottaFS can mount the locations that you select
  automatically when you log in. No window opens.
- **Custom disk name.** In **Advanced**, you can give a location a different
  name in Finder.
- **Updates.** JottaFS tells you when a new version is available. Click
  **Update** to install it. JottaFS opens again with the new version.
- **Fast folders.** JottaFS keeps folder lists for a short time. Large folders
  open quickly.
- **Share links from Finder.** Control-click a file or folder on a
  Jottacloud disk and choose **Copy Jottacloud Link**. For a shared item,
  **Stop Sharing Jottacloud Link** removes the link. Turn on the Finder extension once: JottaFS
  asks, or use **JottaFS → Settings**.
- **Download cache.** JottaFS keeps recently downloaded file data on your Mac
  (1 GB by default). Files that you open again open immediately. Change the
  size in **JottaFS → Settings**.

## Requirements

- A Mac with macOS 27 or later.
- A Jottacloud account.
- To build JottaFS: Xcode with the macOS 27 SDK, and an Apple Developer team.
  The FSKit extension must have a signature.

## Install

There is no released version yet. Build JottaFS from the source code.

1. Clone the repository:

   ```sh
   git clone https://github.com/thomas-alrek/JottaFS.git
   ```

2. Open `JottaFS.xcodeproj` in Xcode.
3. For each target, select your team in **Signing & Capabilities**.
4. Select the **JottaFS** scheme. Then select **Product → Run**.
5. Move the app to the `Applications` folder if you want to mount at login.
   macOS starts login items from a fixed location.

### Turn on the file system extension

macOS must allow the JottaFS extension one time.

1. Open **System Settings**.
2. Go to **General → Login Items & Extensions → File System Extensions**.
3. Turn on **JottaFS**.

The JottaFS app tells you when you must do this. The app finds the change
automatically.

### Allow upload progress (optional)

JottaFS uses a small background helper to show upload progress on file icons
in Finder. If macOS asks, allow **JottaFS** in **System Settings → General →
Login Items & Extensions**.

This step is optional. Without the helper, all functions work. The only
difference is that the progress bar on a file icon does not move during the
upload. It shows the upload as complete at the end.

## Use JottaFS

### Sign in

1. Open JottaFS.
2. Click **Sign In with Jottacloud**. Your browser opens jottacloud.com.
3. Sign in to Jottacloud. The browser tab closes, and JottaFS shows your
   account.

To sign in with a personal login token:

1. Click **Sign in with a personal login token instead**.
2. Click **Open** to open the Jottacloud security settings.
3. Under **Personal login token**, click **Generate**. Copy the token.
4. Paste the token into JottaFS. Click **Sign In**.

You can use a token one time only. JottaFS keeps you signed in after that.
You do not need to keep the token.

### Mount a location

1. Select a location in the list. Locations from a computer backup show under
   the name of the computer.
2. Click **Mount**, or double-click the location.

The location shows in Finder as a disk, and a green checkmark shows next to
it in the list. JottaFS opens it in a Finder window. To mount more
locations, select a different location and click **Mount** again.

### Give the disk a different name

1. Select the location in the list.
2. Click **Advanced**.
3. Type a name in **Name in Finder**. Then click **Save**.

The disk gets the new name the next time you mount it. To use the name of the
location again, delete the name and click **Save**. You cannot change the name
while the location is mounted.

### Unmount

Do one of these steps:

- In JottaFS, select the location and click **Unmount**. Then click
  **Unmount** again to confirm.
- In Finder, click **Eject** next to the disk.

Close all files on the disk before you unmount it. Your files stay in
Jottacloud.

### Mount at login

Select a location, then select **Mount automatically when I log in**. Do this
for each location that you want to mount at login. When you log in, JottaFS
mounts these locations. Then JottaFS closes. No window opens. If a mount
fails, JottaFS opens its window and shows the problem.

### Update JottaFS

JottaFS checks for a new version when it opens and one time each day. When
there is a new version, JottaFS shows it at the top of the window.

1. Click **Update**. JottaFS downloads the new version.
2. JottaFS installs the new version and opens again.

If JottaFS cannot connect to GitHub, it tries again later. It does not show an
error.

### Sign out

Click **Sign Out**, then click **Sign Out** again to confirm. JottaFS unmounts
all mounted locations first. Then it deletes the saved sign-in from your Mac. Your files
stay in Jottacloud.

## The Trash

Finder's Trash shows the items in the Jottacloud trash that come from the
mounted location.

| In Finder | In Jottacloud |
|---|---|
| **Move to Trash** | Moves the item to the Jottacloud trash. |
| **Put Back** | Restores the item to its original location. |
| **Delete Immediately** | Deletes the item permanently. |
| **Empty Trash** | Deletes all items in the Trash of this disk permanently. |
| `rm` in Terminal | Deletes the item permanently, as on a local disk. |

> [!WARNING]
> **Empty Trash** also deletes items that you moved to the trash on
> jottacloud.com or on a different device, if they come from the mounted
> location. You cannot restore permanently deleted items.

Before JottaFS deletes an item permanently, it makes sure that the item is in
the Jottacloud trash. JottaFS never deletes a file that is not in the trash.

## Limits

- You cannot rename the disk in Finder. Use **Advanced** in JottaFS instead.
- You cannot open files that are in the Trash.
- Symbolic links and hard links are not supported.
- JottaFS keeps a full copy of a file on your Mac before the upload starts.
  Jottacloud must know the checksum of the complete file before the upload.
  The maximum file size for a write is 2 GiB.
- The **Get Info** window shows the format as "Unknown (jottacloud)".
- JottaFS keeps folder lists for a short time. Changes that you make on a
  different device can take some seconds to show in Finder.

## Troubleshooting

**"JottaFS couldn't mount the location" with `com.apple.extensionKit.errorDomain
error 2`.** More than one copy of JottaFS is on your Mac (for example an old
copy, or a build from Xcode), and macOS uses the extension of a different copy.

1. Quit JottaFS. Delete the other copies of JottaFS, and empty the Trash.
2. Quit System Settings. Then open **System Settings → General → Login Items
   & Extensions → File System Extensions**, and turn **JottaFS** off and on.
3. Open JottaFS from Applications and mount again.

If the problem continues, restart your Mac.

**The location list is disabled.** Turn on **JottaFS** in **File System
Extensions** (step 2 above). JottaFS finds the change automatically.

## Privacy and security

- JottaFS sends data only to Jottacloud: `id.jottacloud.com`,
  `api.jottacloud.com`, `jfs.jottacloud.com`, `grpc.jotta.cloud` and the
  upload hosts that Jottacloud gives for each upload.
- Browser sign-in uses OAuth 2.0 with PKCE. The browser returns to JottaFS
  through a temporary address on your Mac (`localhost`).
- JottaFS keeps the sign-in tokens in a private file in the app group folder
  on your Mac. Only the JottaFS app and its extension can read this file.
- JottaFS does not write tokens to logs.
- The app and the extension run in the macOS App Sandbox.

## How JottaFS works

| Part | Function |
|---|---|
| `JottaFS` (app) | Sign-in, location list, mount and unmount, mount at login. |
| `JottaFSKitExtension` | The FSKit file system. It shows the location and does all file operations. |
| `JottaFSCore` | The Jottacloud client: sign-in, folder lists, downloads, uploads and the trash. |
| `JottaFSUnmountService` | An XPC service that unmounts the disk through Disk Arbitration. |
| `JottaFSFinderSync` | A Finder extension: **Copy Jottacloud Link** and **Stop Sharing Jottacloud Link** for items on JottaFS disks. |
| `JottaFSProgressAgent` | A background helper that shows upload progress on file icons in Finder. |

## Development

Build the extension code and run the checks:

```sh
swift build --target JottaFSKitExtension
swift run jottafs-checks
```

These commands do not make or sign the app. Use Xcode to build, sign and test
the app and the extension.

After you change the extension:

1. Unmount the disk.
2. Build the app in Xcode.
3. Mount the disk again.

If macOS does not show the new extension, turn **JottaFS** off and on in
**File System Extensions**. If that does not help, restart your Mac.

> [!CAUTION]
> Your Jottacloud account contains your own files. Test changes only on files
> that you make for the test.

## Documentation

- [Jottacloud API research](docs/jottacloud-api-internals.md)
- [FSKit notes](docs/fskit-internals.md)
- [Write support design](docs/write-support-design.md)
- [Trash design](docs/trash-design.md)

## License

JottaFS is available under the [MIT License](LICENSE).

Jottacloud is a trademark of Jottacloud AS.
