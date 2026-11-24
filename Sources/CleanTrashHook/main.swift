import CleanTrashCore
import Foundation

// `cleantrash-hook --source claude|codex|antigravity`
// Reads the agent's hook payload on stdin, forwards it to the CleanTrash notch, and — for permission
// requests — prints the decision the user clicked. Any failure exits 0 silently so the agent keeps going.

let arguments = CommandLine.arguments
var source = AgentSource.claude
if let index = arguments.firstIndex(of: "--source"), index + 1 < arguments.count,
   let parsed = AgentSource(rawValue: arguments[index + 1]) {
    source = parsed
}

func finish(_ output: String?) -> Never {
    if let output {
        FileHandle.standardOutput.write(Data((output + "\n").utf8))
    }
    exit(0)
}

let input = FileHandle.standardInput.readDataToEndOfFile()
guard let json = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any],
      let event = AgentEventNormalizer.normalize(
          json,
          source: source,
          environment: ProcessInfo.processInfo.environment,
          parentPID: getppid()
      ) else {
    finish(source == .antigravity ? "{}" : nil)
}

// Stay under the 120 s hook timeout so we always answer before the agent kills us.
let reply = AgentSocketClient.send(event, replyTimeout: event.awaitsDecision ? 110 : 0)
finish(AgentHookOutput.stdout(for: event, reply: reply))
