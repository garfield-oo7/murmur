import Speech
import Foundation

@main struct Check {
  static func main() async {
    print("SpeechTranscriber.isAvailable:", SpeechTranscriber.isAvailable)
    let st = await SpeechTranscriber.supportedLocales
    print("SpeechTranscriber supported locales:", st.count, st.contains { $0.identifier(.bcp47) == "en-US" } ? "(en-US yes)" : "(en-US no)")
    let inst = await SpeechTranscriber.installedLocales
    print("SpeechTranscriber installed:", inst.map { $0.identifier(.bcp47) })
    let dt = await DictationTranscriber.supportedLocales
    print("DictationTranscriber supported locales:", dt.count)
    let t = SpeechTranscriber(locale: Locale(identifier: "en-US"), preset: .transcription)
    let status = await AssetInventory.status(forModules: [t])
    print("en-US SpeechTranscriber asset status:", status)
  }
}
