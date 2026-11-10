// SPECTRE Capture — spectre-core
package org.spectre.capture.core

sealed class SpectreException(message: String) : Exception(message) {
    class InvalidCaptureId : SpectreException("invalid capture id")
    class OutboxCorrupted : SpectreException("outbox corrupted")
    class OutboxKeyMissing : SpectreException("outbox key missing")
    class OutboxRange : SpectreException("outbox range")
    class NotEnrolled : SpectreException("not enrolled")
    class InvalidEnrollmentPayload(val reason: String) : SpectreException("invalid enrollment payload: $reason")
    class Backend(val code: String, val backendMessage: String) : SpectreException("backend $code")
    class Transport(val reason: String) : SpectreException("transport: $reason")
    class Http(val status: Int) : SpectreException("http $status")
    class SessionExpired : SpectreException("session expired")
    class ProtocolViolation(val reason: String) : SpectreException("protocol: $reason")
}
