cask "jottafs@1.0.3" do
  version "1.0.3"
  sha256 "8a392083c55e83dd9c4311b261d3396a8ea69ca89c258751cc0cdf2911de755f"

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
