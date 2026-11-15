// OWNER: workstream C (app-ui). Scaffold placeholder: replace with the real app entry point.
import Foundation
import NodCore

@main
enum NodMain {
    static let version = "0.1.0"

    static func main() {
        if CommandLine.arguments.contains("--version") {
            print("Nod \(version)")
            return
        }
        print("Nod \(version) scaffold: the app UI is not built yet (default port \(HookServer.defaultPort)).")
    }
}
