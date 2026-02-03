import ArgumentParser

@main
struct Recordit: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "recordit",
        abstract: "Record audio or screen output from the terminal.",
        subcommands: [AudioCommand.self, ScreenCommand.self],
        defaultSubcommand: AudioCommand.self
    )
}
