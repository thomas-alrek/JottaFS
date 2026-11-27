cask "jottafs" do
  version "1.5.0"
  sha256 "ff92442c0985db535b0bea19872a6d237c9ce8d5cfa751a075c0f7d2ddbb13dc"

  url "https://github.com/thomas-alrek/JottaFS/releases/download/v#{version}/JottaFS-#{version}.dmg"
  name "JottaFS"
  desc "Use Jottacloud files in Finder as a disk"
  homepage "https://github.com/thomas-alrek/JottaFS"

  livecheck do
    url :url
    strategy :github_latest
  end

  # JottaFS updates itself from GitHub releases.
  auto_updates true
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
