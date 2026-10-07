//
// Copyright © Agulhas Labs
//

import ArgumentParser
import SiftCore

/// The `sift` root command and the subcommands it registers.
@main
struct SiftCommand: AsyncParsableCommand {
    static var configuration: CommandConfiguration {
        CommandConfiguration(
            commandName: "sift",
            abstract: "Compressed, structurally accurate views of Swift code for agents and humans.",
            version: SiftVersion.current,
            subcommands: [
                InitCommand.self,
                IndexCommand.self,
                StatusCommand.self,
                HelpCommand.self,
                DigestCommand.self,
                WhereCommand.self,
                SearchCommand.self,
                SimilarCommand.self,
                DupesCommand.self,
                StringsCommand.self,
                AffectedCommand.self,
                DiffCommand.self,
                RunCommand.self,
                BuildCommand.self,
                TestCommand.self,
                ReconcileCommand.self,
                ResetCommand.self,
                UsageCommand.self,
                FlakesCommand.self,
                AuditCommand.self,
                ReportCommand.self,
                ReplayHookCommand.self,
                ScanDumpCommand.self,
                MCPCommand.self,
                ServersCommand.self,
                SessionStartCommand.self,
                PreToolUseCommand.self,
                PostToolUseCommand.self,
                StopCommand.self,
                InstallCommand.self,
                DoctorCommand.self,
                InstallHookCommand.self,
                UninstallHookCommand.self,
                UninstallCommand.self,
            ]
        )
    }
}
