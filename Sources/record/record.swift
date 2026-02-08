import ArgumentParser

let appVersion = "0.2.0"

@main
struct Record: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "record",
        abstract: "Record audio, screen, or camera output from the terminal.",
        version: appVersion,
        subcommands: [AudioCommand.self, ScreenCommand.self, CameraCommand.self],
        defaultSubcommand: AudioCommand.self
    )
}
