# Async State Machine
**Async State Machine** aims to provide a way to structure an application thanks to state machines. The goal is to identify the states and the side effects involved in each feature and to model them in a consistent and scalable way.

## Key points:
- Each feature is a Moore state machine: no need for a global store
- State machines are declarative: a DSL offers a natural and concise syntax
- Structured concurrency is at the core: a state machine is an AsyncSequence
- Structured concurrency is at the core: side effects are ran inside tasks
- Structured concurrency is at the core: concurrent transitions can suspend
- State machines are built in complete isolation: tests dont require mocks
- Dependencies are injected per side effect: no global bag of dependencies
- State machines are not UI related: it works with UIKit or SwiftUI

## State Machine
As a picture is worth a thousand words, here’s an example of a state machine that drives the opening of an elevator‘s door:

![](Elevator.jpeg)

<br>
How does it read? 

---
> **INITIALLY**, the elevator is *open* with 0 person inside

>**WHEN** the state is *open*, **ON** the event *personsHaveEntered*, the new state is *open* with ‘n + x’ persons.

>**WHEN** the state is *open*, **ON** the event *closeButtonWasPressed*, the new state is *closing* if there is less than 10 persons (elevator’s capacity is limited).

>**WHEN** the state is *closing*, the *close* action is executed (the door can close at different speeds).

>**WHEN** the state is *closing*, **ON** the event *doorHasLocked*, the new state is *closed*.

---
<br>
What defines this state machine?

- The elevator can be in 3 exclusive states: open, closing and closed. This is the finite set of possible states. The initial state of the elevator is open with 0 person inside.
- The elevator can received 3 events: personsHaveEntered, closeButtonWasPressed and doorHasLocked. This is the finite set of possible events.
- The elevator can perform 1 action: close the door when the state is closing and the number of persons is less than 10. The speed of the doors is determined by the number of persons inside. This is the finite set of possible outputs.
- The elevator can go from one state to another when events are received. This is the finite set of possible transitions.

The assumption we make is that almost any feature can be described in terms of state machines. And to make it as simple as possible, we use a Domain Specific Language.

## The state machine DSL

Here’s the translation of the aforementioned state machine using enums and the **Async State Machine** DSL:

```swift
enum State: DSLCompatible {
    case open(persons: Int)
    case closing(persons: Int)
    case closed
}

enum Event: DSLCompatible {
    case personsHaveEntered(persons: Int)
    case closeButtonWasPressed
    case doorHasLocked
}

enum Output: DSLCompatible {
    case close(speed: Int)
}

let stateMachine = StateMachine(initial: State.open(persons: 0)) { 
    When(state: State.open(persons:)) { _ in
        Execute.noOutput
    } transitions: { persons in
        On(event: Event.personsHaveEntered(persons:)) { newPersons in
            Transition(to: State.open(persons: persons + newPersons))
        }

        On(event: Event.closeButtonWasPressed) { 
            Guard(predicate: persons < 10)
        } transition: { 
            Transition(to: State.closing(persons: persons))
        }
    }
    
    When(state: State.closing(persons:)) { persons in
        Execute(output: Output.close(speed: persons > 5 ? 1 : 2))
    } transitions: { _ in
        On(event: Event.doorHasLocked) {
            Transition(to: State.closed)
        }
    }
}
```

The only requirement to be able to use enums with the DSL is to have them conform to *DSLCompatible*.

## The Runtime

The DSL aims to describe a formal state machine: no side effects, only pure functions!

Side effects are declared in the *Runtime* where one can map outputs to side effect functions:

```swift
func close(speed: Int) async -> Event {
    try? await Task.sleep(nanoseconds: UInt64(1_000_000_000 / speed))
    return .doorHasLocked
}

let runtime = Runtime<State, Event, Output>()
    .map(output: Output.close(speed:), to: close(speed:))
```

> Side effects are functions that returns either an AsyncSequence of events or a single event. Every time the state machine produces the expected output, the corresponding side effect will be executed.

The Runtime can register middleware functions executed on any states or events:

```swift
let runtime = Runtime<State, Event, Output>()
    .map(output: Output.close(speed:), to: close(speed:))
    .register(middleware: { (state: State) in print("State: \(state)") })
    .register(middleware: { (event: Event) in print("Event: \(event)") })
```

The *AsyncStateMachineSequence* can then be instantiated:

```swift
let sequence = AsyncStateMachineSequence(
	stateMachine: stateMachine,
	runtime: runtime
)

for await state in sequence { … }

await sequence.send(Event.personsHaveEntered(persons: 3))
```

## Structured concurrency at the core

**Async State Machine** is 100% built with Swift 5.5 structured concurrency in mind.

### Transitions

- Transitions defined in the DSL are async functions, they will be executed in a non blocking way.
- Event sending is async: `sequence.send(Event.closeButtonWasPressed)` will suspend until the event can be consumed. If an event previously sent is being processed by a transition, the next call to `send(_:)` will await. This prevents concurrent transitions to happen simultaneously which could lead to inconsistent states.

### Side effects

- Side effects are async functions executed in the context of Tasks.
- Task priority can be set in the Runtime: `.map(output: Output.close(speed:), to: close(speed:), priority: .high)`.
- Collaborative task cancellation applies: when the sequence Task is cancelled, every side effect tasks will be cancelled.

### Async sequence

- *AsyncStateMachineSequence* benefits from all the operators associated to *AsyncSequence* (`map`, `filter`, …). (See also [swift async algorithms](https://github.com/apple/swift-async-algorithms))

## How to inject dependencies?

Most of the time, side effects will require dependencies to perform their duty. However, **Async State Machine** expects a side effect to be a function that eventually takes a parameter (from the output) and returns an Event or an AsyncSequence of events. There is no place for dependencies in their signatures.

There are several ways to overcome this:

- Make a business object that captures the dependencies and declares a function that matches the side effect’s signature:

```swift
class ElevatorUseCase {
	let engine: Engine
	
	init(engine: Engine) { self.engine = engine }

	func close(speed: Int) async -> Event {
		try? await Task.sleep(nanoseconds: UInt64(self.engine.delay / speed))
		return .doorHasLocked
	}
}

let useCase = ElevatorUseCase(engine: FastEngine())
let runtime = Runtime<State, Event, Output>()
	.map(output: Output.close(speed:), to: useCase.close(speed:))
```

- Make a factory function that provides a side effect, capturing its dependencies:

```swift
func makeClose(engine: Engine) -> (Int) async -> Event {
	return { (speed: Int) in
		try? await Task.sleep(nanoseconds: UInt64(engine.delay / speed))
		return .doorHasLocked
	}
}

let close = makeClose(engine: FastEngine())
let runtime = Runtime<State, Event, Output>()
	.map(output: Output.close(speed:), to: close)
```

- Use the provided `inject` function (preferred way verbosity wise):

```swift
func close(speed: Int, engine: Engine) async -> Event {
	try? await Task.sleep(nanoseconds: UInt64(engine.delay / speed))
	return .doorHasLocked
}

let closeSideEffect = inject(dep: Engine(), in: close(speed:engine:))
let runtime = Runtime<State, Event, Output>()
	.map(output: Output.close(speed:), to: closeSideEffect)
```

## Testable in complete isolation

State machine definitions do not depend on any dependencies, thus they can be tested without using mocks. **Async State Machine** provides a unit test helper making it even easier:

```swift
XCTStateMachine(stateMachine)
	.assertNoOutput(when: .open(persons: 0))
	.assert(
		when: .open(persons: 0),
		on: .personsHaveEntered(persons: 1),
		transitionTo: .open(persons: 1)
	)
	.assert(
		when: .open(persons: 5),
		on: .closeButtonWasPressed,
		transitionTo: .closing(persons: 5)
	)
	.assertNoTransition(when: .open(persons: 15), on: .closeButtonWasPressed)
	.assert(when: .closing(persons: 1), execute: .close(speed: 2))
	.assert(
		when: .closing(persons: 1),
		on: .doorHasLocked,
		transitionTo: .closed
	)
	.assertNoOutput(when: .closed)
```

## Using Async State Machine with SwiftUI and UIKit

No matter the UI framework you use, rendering a user interface is about interpreting a state. You can use an *AsyncStateMachineSequence* as a reliable state factory.

A simple and naïve SwiftUI usage could be:

```swift
struct ContentView: View {
    @SwiftUI.State var state: State
    let sequence: AsyncStateMachineSequence<State, Event, Output>

    var body: some View {
        VStack {
            Text(self.state.description)
            Button { 
                Task {
                    await self.sequence.send(
	                    Event.personsHaveEntered(persons: 1)
                    )
                }
            } label: { 
                Text("New person")
            }
            Button { 
                Task {
                    await self.sequence.send(
	                    Event.closeButtonWasPressed
	                )
                }
            } label: { 
                Text("Close the door")
            }
        }.task {
            for await state in self.sequence {
                self.state = state
            }
        }
    }
}

…

ContentView(
	state: stateMachine.initial,
	sequence: sequence
)
```

One could wrap up an *AsyncStateMachineSequence* inside a generic `@MainActor class ViewState: ObservableObject` that would expose a `@Published var state: State` and handle the sequence iteration. That would simplify the state management inside the SwiftUI views.

With UIKit, a simple and naïve approach would be:

```swift
let task: Task<Void, Never>!
let sequence: AsyncStateMachineSequence<State, Event, Output>!

override func viewDidLoad() {
	super.viewDidLoad()
	self.task = Task {
		for await state in self.sequence {
			self.render(state: state)
		}
	}
}

@MainActor func render(state: State) {
	…
}

func deinit() {
	self.task.cancel()
}
```

## Extras

- Conditionally resumable `send()` function: 

```swift
await sequence.send(
	.closeButtonWasPressed,
	resumeWhen: .closed
)`
```

Allows to send an event while awaiting for a specific state or set of states to resume.

- Side effect cancellation:

```swift 
Runtime.map(
	output: Output.close(speed:),
	to: close(speed:),
	strategy: .cancelWhenAnyState
)
```

The `close(speed:)` side effect execution will be cancelled when the state machine produces any new states. It is also possible to cancel on a specific state.

- States set:

```swift
When(states: OneOf {
	State.closing(persons:),
	State.closed
}) { _ in
	Execute.noOutput
} transitions: {
	On(event: Event.closeButtonWasPressed) { _ in
		Transition(to: State.opening)
	}
}`
```

It allows to factorize the same transition for a set of states.

- SwiftUI bindings:

```swift
self.sequence.binding(
	get: self.state.description,
	send: .closeButtonWasPressed
)
```

Allows to create a SwiftUI binding on any value, sending an Event when the binding changes.

- Connecting two state machines:

```swift
let connector = Connector<OtherEvent>()

let runtime = Runtime<State, Event, Output>()
	...
	.connectAsSender(to: connector, when: State.closed, send: OtherEvent.refresh)
	

let otherRuntime = Runtime<OtherState, OtherEvent, OtherOutput>()
	...
	.connectAsReceiver(to: connector)
```

It will send the event `OtherEvent.refresh` in the other state machine when the first state machine's state is `State.closed`.
