import Foundation

/// Practice texts for the Read Aloud screen. Template matching needs several takes of each
/// word, so these repeat a small command vocabulary many times in different positions,
/// rather than covering lots of words once.
enum Passages {
    struct Passage: Identifiable, Hashable {
        var title: String
        var text: String
        var id: String { title }
    }

    static let targetWords = ["yes", "no", "next", "back", "stop", "play", "pause", "open", "call", "send", "up", "down"]

    static let all: [Passage] = [
        Passage(title: "Remote control", text: """
        Play. Pause. Play again. Next. Next. Back. Stop.
        Turn it up. Up. Up. Now down. Down. Stop.
        Open the music. Play. Next song. Back one. Pause.
        Yes, play it. No, stop. Yes. No. Yes. No.
        Open. Call. Send. Up. Down. Next. Back. Play. Pause. Stop.
        """),
        Passage(title: "Phone assistant", text: """
        Call Sam. No. Stop. Call Alex. Yes.
        Open messages. Send it. Yes, send. No, go back.
        Back. Back. Open mail. Next. Next. Send. Stop.
        Turn the volume up, then down, then up. Pause. Play.
        Yes. No. Call. Send. Open. Next. Back. Stop.
        """),
        Passage(title: "Short story", text: """
        "Stop," she said, "go back." He did not stop. He went up the hill and then down.
        "Open the gate," he called. "No," she said. "Yes," he said. "Next time, send a call first."
        So next time he did call. "Pause," she said, "then play the song again."
        He pressed play. Then pause. Then play. "Up," she said. "Down. Stop. Yes. Back. Send. Open."
        """),
        Passage(title: "Word drill", text: """
        Yes yes yes. No no no. Next next next. Back back back.
        Stop stop stop. Play play play. Pause pause pause. Open open open.
        Call call call. Send send send. Up up up. Down down down.
        Yes no. Next back. Stop play. Pause open. Call send. Up down.
        """),
    ]
}
