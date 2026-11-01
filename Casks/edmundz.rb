# Updated automatically by the "cask" job in .github/workflows/release.yml.
cask "edmundz" do
  version "1.0.0"
  sha256 "f9408287fcfde09a21ea47ec3af66aad32894379834e7dea14ce607734f3801f"

  url "https://github.com/jaydenrasmussen/Edmundz/releases/download/v#{version}/Edmundz-#{version}.dmg"
  name "Edmundz"
  desc "Markdown editor where the page is the editor"
  homepage "https://github.com/jaydenrasmussen/Edmundz"

  depends_on macos: ">= :tahoe"
  depends_on arch: :arm64

  app "Edmundz.app"

  zap trash: [
    "~/Library/Application Support/Edmundz",
    "~/Library/Caches/app.edmundz.Edmundz",
    "~/Library/Preferences/app.edmundz.Edmundz.plist",
  ]
end
