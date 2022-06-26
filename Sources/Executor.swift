//
//  Executor.swift
//  
//
//  Created by Thibault WITTEMBERG on 25/06/2022.
//

import Foundation

struct TaskInProgress<S> {
  let cancellationPredicate: (S) -> Bool
  let task: Task<Void, Never>
}

actor Executor<S, E, O>: Sendable
where S: DSLCompatible, E: DSLCompatible & Sendable, O: DSLCompatible {
  let outputResolver: @Sendable (S) -> O?
  let nextStateResolver: @Sendable (S, E) async -> S?
  let sideEffectResolver: @Sendable (O) -> SideEffect<S, E, O>?
  let eventHandler: (E) async -> Void

  let eventMiddlewares: OrderedStorage<Middleware<E>>
  var stateMiddlewares: OrderedStorage<Middleware<S>>
  var tasksInProgress: OrderedStorage<TaskInProgress<S>>
  
  init(
    stateMachine: StateMachine<S, E, O>,
    runtime: Runtime<S, E, O>
  ) {
    self.outputResolver = stateMachine.output(for:)
    self.nextStateResolver = stateMachine.reduce(when:on:)
    self.sideEffectResolver = runtime.sideEffects(for:)
    self.eventHandler = { event in await runtime.eventChannel.send(event) }
    self.stateMiddlewares = OrderedStorage(contentOf: runtime.stateMiddlewares)
    self.eventMiddlewares = OrderedStorage(contentOf: runtime.eventMiddlewares)
    self.tasksInProgress = OrderedStorage()
  }

  func register(
    taskInProgress task: Task<Void, Never>,
    cancelOn predicate: @escaping (S) -> Bool
  ) {
    // registering task for eventual cancellation
    let taskIndex = self.tasksInProgress.append(
      TaskInProgress(
        cancellationPredicate: predicate,
        task: task
      )
    )

    // cleaning when task is done
    Task {
      await task.value
      self.tasksInProgress.remove(index: taskIndex)
    }
  }

  func cancelTasksInProgress(
    for state: S
  ) {
    self
      .tasksInProgress
      .indexedValues
      .filter { _, taskInProgress in taskInProgress.cancellationPredicate(state) }
      .forEach { index, taskInProgress in
        taskInProgress.task.cancel()
        self.tasksInProgress.remove(index: index)
      }
  }

  func cancelTasksInProgress() {
    self
      .tasksInProgress
      .values
      .forEach { taskInProgress in taskInProgress.task.cancel() }

    self.tasksInProgress.removeAll()
  }

  nonisolated func process(event: E) async {
    // executes event middlewares for this event
    await self.process(middlewares: self.eventMiddlewares.values, using: event)
  }

  nonisolated func process(state: S) async {
    // cancels tasks that are known to be cancellable for this state
    await self.cancelTasksInProgress(for: state)

    // executes state middlewares for this state
    await self.process(middlewares: self.stateMiddlewares.values, using: state)

    // executes side effect for this state if any
    await self.executeSideEffect(for: state)
  }

  nonisolated func process<T>(middlewares: [Middleware<T>], using value: T) async {
    let task: Task<Void, Never> = Task {
      await withTaskGroup(of: Void.self) { group in
        middlewares.forEach { middleware in
          _ = group.addTaskUnlessCancelled(priority: middleware.priority) {
            await middleware.execute(value)
          }
        }
      }
    }

    // registering the task to be able to eventually cancel it if needed.
    // middlewares are never cancelled on new state/event
    await self.register(taskInProgress: task, cancelOn: { _ in  false })
  }

  nonisolated func executeSideEffect(for state: S) async {
    guard
      let output = self.outputResolver(state),
      let sideEffect = self.sideEffectResolver(output),
      let events = sideEffect.execute(output) else { return }

    let task: Task<Void, Never> = Task(priority: sideEffect.priority) { [weak self] in
      do {
        for try await event in events {
          await self?.eventHandler(event)
        }
      } catch {
        // side effect cannot fail (should not be necessary to have a `for try await ...` loop but
        // AnyAsyncSequence masks the non throwable nature of side effects
        // could be fixed by saying the a side effect is (O) -> any AsyncSequence<E, Never>
      }
    }

    await self.register(
      taskInProgress: task,
      cancelOn: sideEffect.strategy.predicate
    )
  }

  func register(temporaryMiddleware: @Sendable @escaping (S) async -> Void) -> Int {
    self.stateMiddlewares.append(
      Middleware<S>(execute: temporaryMiddleware, priority: nil)
    )
  }

  func unregisterTemporyMiddleware(index: Int) {
    self.stateMiddlewares.remove(index: index)
  }

  deinit {
    self.cancelTasksInProgress()
  }
}
