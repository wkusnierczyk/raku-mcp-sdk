# Two Bugs, One Symptom

A debugging war story from implementing SSE client transport in a Raku MCP SDK.

---

The task seemed straightforward: add legacy SSE transport to a Raku [MCP SDK](https://github.com/anthropics/model-context-protocol). The server side went smoothly — Cro makes it easy to push `text/event-stream` responses. The client side destroyed an afternoon.

The symptom was simple. `is-connected` stays `False`. Forever. No error, no exception, no timeout message. Just... nothing happens.

## The hunt

The maddening part about debugging concurrency issues is how many hypotheses you generate per hour.

The SSE client needed to: (1) open a GET to `/sse`, (2) parse the `event: endpoint` line to learn the POST URL, (3) report itself as connected. Step 1 wasn't completing. Or was it? Hard to tell when your debug prints don't appear either.

Here's what I tried, in roughly this order:

- `start { await $client.get(...) }` — GET takes 5–10 seconds to resolve
- `$client.get(...).then(-> $p { ... })` — `.then` callback also delayed
- `react { whenever $resp.body-byte-stream }` — `whenever` doesn't fire
- `Supply.tap(...)` — tap callback delayed
- `RAKUDO_MAX_THREADS=128` — no help

Each approach had the same shape: code that works fine in isolation, fails when a Cro HTTP server is running in the same process.

## Bug 1: Thread pool starvation

Raku's `start` blocks, `.then` callbacks, and `react/whenever` all share a single `ThreadPoolScheduler`. Cro uses these same primitives. When a Cro server holds open long-lived SSE streams — which are `Supply` pipelines sitting in `whenever` blocks — and a Cro client in the same process needs scheduler slots to resolve its HTTP response pipeline, they compete for the same pool.

Neither side is doing anything wrong. The starvation is emergent.

Debug output told the story:

```
SSE-CLIENT: before get
connected=False
connected=False
connected=False
SSE-CLIENT: after get, status=200
```

The GET resolves. Just 10 seconds too late, after the test's polling loop has already given up.

The fix: escape the shared pool entirely. `Thread.start` creates a real OS thread outside Raku's scheduler. But there's a wrinkle — `await` doesn't work inside `Thread.start`. It silently returns `Nil`:

```
THREAD: entering sse-loop
SSE-LOOP: before get
THREAD: exited sse-loop
```

No error. No exception. `await` just... doesn't block. The solution is `.result`, which is a synchronous wait on a Promise and works correctly outside the scheduler:

```raku
method !connect-sse() {
    my $self = self;
    my $url = $!url;
    # Use Thread.start to avoid thread pool scheduler issues with Cro
    Thread.start({
        my $client-class = (require ::('Cro::HTTP::Client'));
        my $client = $client-class.new;
        my $resp = $client.get($url,
            headers => [Accept => 'text/event-stream']).result;
        react {
            whenever $resp.body-byte-stream -> $chunk {
                $self.handle-sse-chunk($chunk);
            }
        }
        CATCH { default { } }
    });
}
```

Connection established. Data flowing. Chunks arriving. And `is-connected` stays `False`.

## Bug 2: The invisible space

Same symptom. Completely different cause.

The SSE parser receives `"event: endpoint\ndata: http://...\n\n"`. It splits each line on `:`, getting field `"event"` and value `" endpoint"`. Per the SSE spec, a single leading space after the colon should be stripped. The code did this:

```raku
$value = $value.subst(/^ /, '') if $value.defined;
```

Looks right. Does nothing.

In Raku regexes, whitespace is insignificant by default. The regex `/^ /` means "anchor to start of string." The space is formatting — syntactic sugar for readability of complex patterns. It is not a literal space character. So `subst` matches a zero-width position at index 0, replaces nothing, and returns the original string unchanged.

The event type becomes `" endpoint"` (with a leading space). The check `$!sse-event-type eq 'endpoint'` fails. The POST endpoint is never set. `is-connected` stays `False`.

Debug output, once I added it in the right place:

```
HANDLE-CHUNK: empty line, event-type=[ endpoint] data=[ http://127.0.0.1:39652/message]
```

That leading space in `[ endpoint]` is the entire bug. The fix avoids regex entirely:

```raku
$value = $value.substr(1) if $value.defined && $value.starts-with(' ');
```

## Why the combination was brutal

Bug 1 prevented data from arriving in time, so bug 2 was invisible. You can't debug a parser that never receives input.

Once bug 1 was fixed, the symptom was identical: `is-connected` stays `False`. No error. No exception. Same silent wrongness, completely unrelated root cause. There was no moment where one bug was fixed and the system partially worked — it went from "broken for reason A" to "broken for reason B" with no observable change in behavior.

## Reflections

The regex design choice is defensible. When you write complex patterns — and Raku grammars get genuinely complex — insignificant whitespace is a gift:

```raku
/ <ident> \s* '=' \s* <value> /
```

is easier to read than:

```
/\w+\s*=\s*\S+/
```

But `/ ^ /` silently meaning something different from every other regex flavor on earth is a trap. It doesn't warn. It doesn't fail. It matches, successfully, matching nothing. A language where `/foo bar/` doesn't match `"foo bar"` has an onboarding cost, and that cost is paid in debugging sessions like this one.

The thread pool issue is subtler and arguably more interesting. It's not a bug in Raku or Cro. It's an emergent property of running a server and client in the same process when both rely on cooperative scheduling. The kind of thing that works fine in production (separate processes) and fails in tests (same process). The fix — `Thread.start` with `.result` instead of `start` with `await` — is the sort of incantation you'd never guess from the documentation.

Two bugs. One symptom. Zero error messages. A good afternoon.
