# The tap formula for sift. Generated from this template by Distribution/homebrew/build.sh, which
# fills in the version and the checksum of the release it is cutting — never edit those by hand.
#
# The URL is built from the artifact being released, not from a filename pattern: `make-dist.sh`
# stamps a public-commit or source-tree hash into the name it produces, so a pattern here would point at a file that is never
# uploaded under that name.
#
# The formula installs the binary and the agent rule and stops there. Registering the MCP server and
# the hooks writes to ~/.claude, which is the user's own configuration and shared with tools this one
# does not own, so it stays an explicit command in the caveats rather than something a package
# manager does to you. `sift install` is that explicit command: it finds Claude Code, Cursor and Codex
# and sets sift up in the ones you accept.
class Sift < Formula
  desc "Swift code index and truthful build/test runner for AI coding agents"
  homepage "https://github.com/Agulhas-Labs/sift"
  url "@URL@"
  sha256 "@SHA256@"
  license "Apache-2.0"

  depends_on arch: :arm64
  depends_on macos: :ventura

  def install
    bin.install "sift"
    pkgshare.install "Sift.md", "INSTALL.md", "LICENSE.txt", "THIRD-PARTY-NOTICES.txt"
  end

  def caveats
    <<~EOS
      Installing this package does not write to ~/.claude, which is your own configuration. To set sift
      up in Claude Code, Cursor and Codex (the server, and the hooks that make an agent reach for it):

        sift install

      It finds each agent, asks once per agent, and says what it wrote. Then, in a Swift repository,
      `sift status` — the first query indexes it. Start a NEW Claude Code session afterwards (restart
      Cursor; restart Codex and approve the trust prompt it shows); running ones keep the old server
      process and the old context.
    EOS
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/sift --version")
    # A repository is what it answers about, and refusing to answer outside one is the contract.
    assert_match "not inside a git repository", shell_output("#{bin}/sift status 2>&1", 1).downcase
  end
end
