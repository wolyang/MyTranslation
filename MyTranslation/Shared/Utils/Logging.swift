import Foundation

private enum LogLevel: String {
    case info = "INFO"
    case warn = "WARN"
    case error = "ERROR"
}

/// 로그 레벨별 포맷 일관성을 제공하는 경량 로깅 유틸리티.
/// - 특징: 기본 인자로 파일명·함수명·라인을 자동으로 포함해 호출 지점을 기록합니다.
/// - 사용 예:
///   ```
///   Log.info("데이터 요청 시작")
///   Log.warn("응답 지연 감지")
///   Log.error("파싱 실패: \(error.localizedDescription)")
///   // 출력 예시
///   // [2025-01-03 10:12:45.123] [INFO] HomeViewModel.fetch():42 - 데이터 요청 시작
///   // [2025-01-03 10:12:47.987] [WARN] HomeViewModel.fetch():68 - 응답 지연 감지
///   // [2025-01-03 10:12:48.110] [ERROR] HomeViewModel.fetch():71 - 파싱 실패: unexpectedEOF
///   ```
enum Log {
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        return formatter
    }()

    private static func log(
        _ level: LogLevel,
        _ msg: String,
        file: String = #file,
        function: String = #function,
        line: Int = #line
    ) {
        let fileName = URL(fileURLWithPath: file).lastPathComponent
        let timestamp = dateFormatter.string(from: Date())
        print("[\(timestamp)] [\(level.rawValue)] \(fileName).\(function):\(line) - \(msg)")
    }

    /// INFO 레벨 로그를 출력합니다.
    /// - Parameters:
    ///   - msg: 남길 메시지.
    ///   - file: 호출 파일 경로(기본값: `#file`).
    ///   - function: 호출 함수명(기본값: `#function`).
    ///   - line: 호출 라인(기본값: `#line`).
    /// - Example:
    ///   ```
    ///   Log.info("사용자 세션 초기화")
    ///   // [2025-01-03 10:15:10.001] [INFO] SessionManager.init():27 - 사용자 세션 초기화
    ///   ```
    static func info(
        _ msg: String,
        file: String = #file,
        function: String = #function,
        line: Int = #line
    ) {
        log(.info, msg, file: file, function: function, line: line)
    }

    /// WARN 레벨 로그를 출력합니다.
    /// - Parameters:
    ///   - msg: 남길 메시지.
    ///   - file: 호출 파일 경로(기본값: `#file`).
    ///   - function: 호출 함수명(기본값: `#function`).
    ///   - line: 호출 라인(기본값: `#line`).
    /// - Example:
    ///   ```
    ///   Log.warn("네트워크 지연 발생")
    ///   // [2025-01-03 10:15:11.245] [WARN] SessionManager.load():54 - 네트워크 지연 발생
    ///   ```
    static func warn(
        _ msg: String,
        file: String = #file,
        function: String = #function,
        line: Int = #line
    ) {
        log(.warn, msg, file: file, function: function, line: line)
    }

    /// ERROR 레벨 로그를 출력합니다.
    /// - Parameters:
    ///   - msg: 남길 메시지.
    ///   - file: 호출 파일 경로(기본값: `#file`).
    ///   - function: 호출 함수명(기본값: `#function`).
    ///   - line: 호출 라인(기본값: `#line`).
    /// - Example:
    ///   ```
    ///   Log.error("토큰 재발급 실패")
    ///   // [2025-01-03 10:15:12.512] [ERROR] SessionManager.refresh():73 - 토큰 재발급 실패
    ///   ```
    static func error(
        _ msg: String,
        file: String = #file,
        function: String = #function,
        line: Int = #line
    ) {
        log(.error, msg, file: file, function: function, line: line)
    }
}
