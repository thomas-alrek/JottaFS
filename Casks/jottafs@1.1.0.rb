cask "jottafs@1.1.0" do
  version "1.1.0"
  sha256 "1b58fb2868a0f9a380f5371161146e697a22f830e89294d49ffe1facbbeb7dcf"

  url "https://github.com/thomas-alrek/JottaFS/releases/download/v#{version}/JottaFS-#{version}.dmg"
  name "JottaFS"
  desc "Use Jottacloud files in Finder as a disk"
  homepage "https://github.com/thomas-alrek/JottaFS"

  livecheck do
    skip "This cask installs one fixed version."
  end

  # JottaFS updates itself from GitHub releases.
  auto_updates true
  conflicts_with cask: "jottafs"
  depends_on arch: :arm64
  depends_on macos: :golden_gate

  app "JottaFS.app"

  uninstall launchctl: "no.alrek.jottafs.progress",
            quit:      [
              "no.alrek.jottafs",
              "no.alrek.jottafs.findersync",
            ]

  zap trash: [
    "~/Library/Application Scripts/group.no.alrek.jottafs",
    "~/Library/Application Scripts/no.alrek.jottafs",
    "~/Library/Application Scripts/no.alrek.jottafs.extension",
    "~/Library/Application Scripts/no.alrek.jottafs.findersync",
    "~/Library/Containers/no.alrek.jottafs",
    "~/Library/Containers/no.alrek.jottafs.extension",
    "~/Library/Containers/no.alrek.jottafs.findersync",
    "~/Library/Containers/no.alrek.jottafs.progress",
    "~/Library/Group Containers/group.no.alrek.jottafs",
  ]

  caveats <<~EOS
    Open JottaFS once from Applications. Then turn on JottaFS in
      System Settings → General → Login Items & Extensions → File System Extensions
    JottaFS tells you when to do this.

    Unmount your Jottacloud disks before you uninstall JottaFS.
  EOS
end
