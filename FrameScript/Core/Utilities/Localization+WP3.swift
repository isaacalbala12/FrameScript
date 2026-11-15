import Foundation

extension L10n {
    /// Strings owned by fix package WP3. Every key needs .english, .russian and .spanish.
    static let wp3Strings: [AppLanguage: [String: String]] = [
        .english: [
            "duration.samples.one": "%d good take",
            "duration.samples.other": "%d good takes",
            "recording.orphanTakePath": "The take file is still on disk: %@",
            "recording.error.stoppedDuringStart": "OBS stopped before the recording could start.",
            "recording.obs.nonLoopbackWarning": "This is not a local host. OBS commands travel unencrypted over the network, so only use a remote host on a network you trust.",
            "recording.manual.probeFailed": "FrameScript could not read this file’s duration. Enter it manually."
        ],
        .russian: [
            "duration.samples.one": "%d хороший дубль",
            "duration.samples.few": "%d хороших дубля",
            "duration.samples.many": "%d хороших дублей",
            "recording.orphanTakePath": "Файл дубля сохранён на диске: %@",
            "recording.error.stoppedDuringStart": "OBS остановился до начала записи.",
            "recording.obs.nonLoopbackWarning": "Это не локальный хост. Команды OBS передаются по сети без шифрования, поэтому используйте удалённый хост только в доверенной сети.",
            "recording.manual.probeFailed": "FrameScript не удалось прочитать длительность файла. Введите её вручную."
        ],
        .spanish: [
            "duration.samples.one": "%d toma buena",
            "duration.samples.other": "%d tomas buenas",
            "recording.orphanTakePath": "El archivo de la toma sigue en el disco: %@",
            "recording.error.stoppedDuringStart": "OBS se detuvo antes de que la grabación pudiera empezar.",
            "recording.obs.nonLoopbackWarning": "Este host no es local. Los comandos de OBS viajan por la red sin cifrar, así que usa un host remoto solo en una red de confianza.",
            "recording.manual.probeFailed": "FrameScript no pudo leer la duración de este archivo. Indícala a mano."
        ]
    ]
}
