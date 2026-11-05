# DCG expansion experiment

This standalone SWI-Prolog prototype exposes `iso_phrase/2` and `iso_phrase/3`
to explore DCG body expansion, error timing, cut scope and caller context.
It is not connected to the demonstrator or its runtime packages. Its name is
experimental; these tests do not establish ISO or Appendix B conformance.

The source comment cites Ulrich Neumerkel's
[dcgs_exp.pl](https://www.complang.tuwien.ac.at/ulrich/iso-prolog/dcgs/dcgs_exp.pl)
as its expansion reference. The implementation here omits input/remainder type
checks. The numbered tests retain the identifiers of the earlier phrase
comparison; they are local regression expectations, not a complete upstream
test suite.

Run from the repository root:

```sh
swipl -f none -q -s experiments/iso-dcg/test_iso_dcg.pl -g run_tests -t halt
```

On 5 November 2026, all 51 expanded test instances passed on SWI-Prolog 10.1.19
for fat-darwin.
The tests collect every answer of each finite probe and compare answer order,
variable sharing or the expected exception. Additional probes cover caller
module lookup, a body instantiated during execution and cyclic terminals.
The `host_24`–`host_26` probes explicitly exercise SWI's raw `(-->)/2` handling;
they run in this disposable test process and remove their temporary clause.

## Review limits

- The implementation uses SWI's module machinery (`strip_module/3` and
  `meta_predicate/1`) and internal `'$skip_list'/3`. Portability has not been
  established.
- Some expected errors include SWI's expanded callable term or module-qualified
  procedure indicator. These expectations must be reviewed before becoming
  shared language tests.
- The omitted input/remainder checks are an experimental choice, not a decision
  about the language's required representations or validation rules.
- Cut scope, eager expansion and error timing require an explicit language-level
  review before any runtime adoption. Passing this local suite does not settle
  those decisions.

Runtime integration and a common multi-mode test selection remain deferred.
