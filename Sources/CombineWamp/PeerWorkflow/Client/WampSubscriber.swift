import Combine
import Foundation
import FoundationExtensions

public protocol WampSubscriberProtocol {
    func subscribe(topic: URI, onUnsubscribe: @escaping (Result<Message.Unsubscribed, ModuleError>) -> Void)
    -> AnyPublisher<Message.Event, ModuleError>
}

/// WAMP Subscriber is a WAMP Client role that allows this Peer to subscribe to a topic and receive events related to it
public struct WampSubscriber: WampSubscriberProtocol {
    let session: WampSession

    public init(session: WampSession) {
        self.session = session
    }
    
    public func subscribe(topic: URI, onUnsubscribe: @escaping (Result<Message.Unsubscribed, ModuleError>) -> Void = { _ in })
    -> AnyPublisher<Message.Event, ModuleError> {
        let session = self.session
        guard let id = session.idGenerator.next() else { return Fail(error: .sessionIsNotValid).eraseToAnyPublisher() }
        let messageBus = session.messageBus

        return session.send(
            Message.subscribe(.init(request: id, options: [:], topic: topic))
        )
        .flatMap { () -> Publishers.Promise<Message.Subscribed, ModuleError> in
            messageBus
                .setFailureType(to: ModuleError.self)
                .flatMap { message -> AnyPublisher<Message.Subscribed, ModuleError> in
                    if case let .subscribed(subscribed) = message, subscribed.request == id {
                        return Just<Message.Subscribed>(subscribed).setFailureType(to: ModuleError.self).eraseToAnyPublisher()
                    }

                    if case let .error(error) = message, error.requestType == Message.Subscribed.type, error.request == id {
                        return Fail<Message.Subscribed, ModuleError>(error: .commandError(error)).eraseToAnyPublisher()
                    }

                    return Empty().eraseToAnyPublisher()
                }
                .promise(onEmpty: { .failure(.sessionIsNotValid) })
        }
        .map { subscribedMessage -> AnyPublisher<Message.Event, ModuleError> in
            messageBus
                .setFailureType(to: ModuleError.self)
                .compactMap { message in
                    guard case let .event(event) = message,
                          event.subscription == subscribedMessage.subscription
                    else { return nil }
                    return event
                }
                .handleEvents(
                    receiveCancel: { [weak session] in
                        guard let session = session else {
                            onUnsubscribe(.failure(.sessionIsNotValid))
                            return
                        }
                        self.unsubscribe(subscription: subscribedMessage.subscription)
                            .run(onSuccess: { onUnsubscribe(.success($0)) },
                                 onFailure: { onUnsubscribe(.failure($0)) }
                            )
                            .store(in: &session.cancellables)

                    }
                )
                .eraseToAnyPublisher()
        }
        .switchToLatest()
        .eraseToAnyPublisher()
    }

    private func unsubscribe(subscription: WampID) -> Publishers.Promise<Message.Unsubscribed, ModuleError> {
        guard let id = session.idGenerator.next() else { return .init(error: .sessionIsNotValid) }
        let messageBus = session.messageBus

        return session.send(
            Message.unsubscribe(.init(request: id, subscription: subscription))
        )
        .flatMap { () -> Publishers.Promise<Message.Unsubscribed, ModuleError> in
            messageBus
                .setFailureType(to: ModuleError.self)
                .flatMap { message -> AnyPublisher<Message.Unsubscribed, ModuleError> in
                    if case let .unsubscribed(unsubscribed) = message, unsubscribed.request == id {
                        return Just<Message.Unsubscribed>(unsubscribed).setFailureType(to: ModuleError.self).eraseToAnyPublisher()
                    }

                    if case let .error(error) = message, error.requestType == Message.Unsubscribed.type, error.request == id {
                        return Fail<Message.Unsubscribed, ModuleError>(error: .commandError(error)).eraseToAnyPublisher()
                    }

                    return Empty().eraseToAnyPublisher()
                }
                .promise(onEmpty: { .failure(.sessionIsNotValid) })
        }
        .promise
    }
}
