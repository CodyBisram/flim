import UserNotifications

/// Puts the friend's photo into a push before it is shown (1.6.3). The server sends
/// `mutable-content` and a signed URL in `flim.img` only on pushes that carry the three reaction
/// buttons (`NotificationActions.reactCategory` in the app): the noon roundup's newest post and
/// "tagged you". Reacting to a photo you can see is the point; without the picture the buttons
/// would ask for a reaction to something unseen.
///
/// Anything that goes wrong delivers the notification exactly as it arrived, words only. The
/// extension has about thirty seconds and a small memory budget, and it holds no session: the URL
/// is already signed, so nothing here can read anything the push did not name.
final class NotificationService: UNNotificationServiceExtension {
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var best: UNMutableNotificationContent?
    private var task: URLSessionDownloadTask?
    /// The download finishes on URLSession's queue and the expiry call comes on the system's: the
    /// lock keeps the photo from landing on a notification already handed back, and the handler
    /// from being called twice.
    private let lock = NSLock()

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        self.contentHandler = contentHandler
        guard let content = request.content.mutableCopy() as? UNMutableNotificationContent else {
            contentHandler(request.content)
            return
        }
        best = content
        guard let url = PushImage.url(from: content.userInfo) else {
            deliver()
            return
        }
        task = URLSession.shared.downloadTask(with: url) { [weak self] location, response, _ in
            guard let self else { return }
            if let location,
               let http = response as? HTTPURLResponse, http.statusCode == 200,
               let attachment = PushImage.attachment(movingFrom: location) {
                self.lock.lock()
                self.best?.attachments = [attachment]
                self.lock.unlock()
            }
            self.deliver()
        }
        task?.resume()
    }

    /// The system's last call: show what there is, which is the words.
    override func serviceExtensionTimeWillExpire() {
        task?.cancel()
        deliver()
    }

    private func deliver() {
        lock.lock()
        let handler = contentHandler
        let content = best
        contentHandler = nil
        lock.unlock()
        if let handler, let content { handler(content) }
    }
}
