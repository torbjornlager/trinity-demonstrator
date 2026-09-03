# Statechart `<spawn>`

`<spawn>` uses explicit attributes for its type and required invocation
operands, and a typed `options` list for every optional setting:

```xml
<spawn type="server"
       callback="counter"
       state="0"
       options="[name(counter_server), monitor(true), link(false)]">
    counter(inc, N, N1, N1) :- N1 is N + 1.
</spawn>
```

The body is preserved as one `src_text/1` option. Required operand values and
members of `options` are parsed as Prolog terms and must be ground.
The `type` attribute is required and must name one of the five types below.

| Type | Additional required attributes | Type-specific options |
| --- | --- | --- |
| `actor` | `goal` | `target` |
| `toplevel` | none | `session`, `time_limit`, `idle_limit`, `target`, `name` |
| `server` | `callback`, `state` | `name` |
| `supervisor` | `children` | `strategy`, `intensity`, `period`, `name` |
| `statechart` | exactly one XML source | `name`, `trace` |

All types support `monitor(true|false)`, `link(true|false)`, `node`, and
`io_target`. Actor, toplevel, server, and supervisor spawns use Prolog source
options `src_text`, `src_uri`, `src_list`, and `src_predicates`; their
spellings are the only supported source-option names.

A nested statechart uses exactly one `src_text` or `src_uri` as its XML source.
`src_list` and `src_predicates` are additional Prolog sources loaded into that
nested chart's private execution module. Its root requires `version="0.2"`.
Inline XML must therefore be placed in a CDATA body:

```xml
<spawn type="statechart"
       options="[monitor(true), trace(false), src_list([helper(ok)])]"><![CDATA[
    <statechart version="0.2" initial="ready">
        <state id="ready" />
    </statechart>
]]></spawn>
```

The remaining deliberate restrictions are:

- arbitrary actor implementation options not in the table above;
- multiple XML sources for one nested statechart;
- `trace` on non-statechart children, where it has no corresponding runtime
  meaning.

An explicit toplevel `target` replaces the containing chart as the recipient
of query results. The chart still receives its local `spawned(Pid)` event.
For a nested statechart, `trace(false)` suppresses that child's trace without
changing the containing interpreter's trace setting.

Non-source option names may occur only once in the `options` list. Multiple
Prolog source fragments are the exception and retain their declaration order.
Every invoked child is owned by the state containing the `<spawn>` and is
cancelled when that state exits.
