:- use_module('../examples/portable_json_swi').
:- ['portable_json_cases.pl'].
:- begin_tests(portable_json).
test(shared_codec) :- portable_json_regression.
test(native_dict_all_values) :-
    portable_json_from_dict(_{'[]':[], empty:"", text:"[]", truth:true,
                             word:"true", no:false, nil:null, nested:_{x:1}}, P),
    portable_json_get(P,'[]',[]), portable_json_get(P,empty,string([])),
    portable_json_get(P,text,string([91,93])), portable_json_get(P,truth,@(true)),
    portable_json_get(P,word,string([116,114,117,101])), portable_json_get(P,no,@(false)),
    portable_json_get(P,nil,@(null)), portable_json_get(P,nested,json([string([120])=1])).
test(classic_roundtrip) :-
    Classic=json(['[]'='[]',x= @(true),x=true,arr=[],nested=json([])]),
    portable_json_from_classic(Classic,P),portable_json_to_classic(P,C),
    assertion(C==Classic),portable_json_get(P,x,@(true)).
test(variable_not_bound, [throws(error(domain_error(json_native_value,_),_))]) :-
    portable_json_from_dict(_, _).
test(nested_variable_not_bound) :-
    catch(portable_json_from_dict(_{x:X},_),error(domain_error(json_native_value,_),_),Caught=yes),
    assertion(Caught==yes),assertion(var(X)).
test(invalid_native, [throws(error(domain_error(json_native_value,_),_))]) :-
    portable_json_from_classic(json([x=bogus(term)]),_).
test(cyclic_native, [throws(error(domain_error(json_native_value,_),_))]) :-
    X=[X],portable_json_from_dict(X,_).
test(cyclic_portable, [fail]) :- X=[X],portable_json_value(X).
test(variable_key_does_not_bind, [fail]) :- portable_json_get(json([]),_,_).
test(invalid_character, [throws(error(type_error(character_list,_),_))]) :-
    portable_json_chars(_,[ab]).
:- end_tests(portable_json).
