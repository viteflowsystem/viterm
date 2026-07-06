# Homebrew Cask テンプレート。
#
# このファイルは最終的にタップ用リポジトリ(例: viteflowsystem/homebrew-tap の
# Casks/viterm.rb)に置く。ここ(viterm リポジトリ)にはひな形として保管しておく。
#
# インストール:  brew install --cask viteflowsystem/tap/viterm
#
# リリースのたびに version と sha256 を scripts/release.sh の出力で更新する。
# url は DMG の公開ダウンロード先(GitHub Releases か公開ストレージ)。
cask "viterm" do
  version "0.1.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/viteflowsystem/viterm/releases/download/v#{version}/viterm-#{version}.dmg"
  name "viterm"
  desc "AI coding agent を並列運用するネイティブ macOS ターミナル"
  homepage "https://viterm.viteflowsystem.com"

  depends_on macos: ">= :sequoia"

  app "viterm.app"

  zap trash: [
    "~/.config/viterm",
    "~/Library/Application Support/viterm",
  ]
end
