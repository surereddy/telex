// $Id: Scope.cc 6219 2008-10-01 05:39:07Z vern $
//
// See the file "COPYING" in the main distribution directory for copyright.

#include "config.h"

#include "ID.h"
#include "Val.h"
#include "Scope.h"

static scope_list scopes;
static Scope* top_scope;

extern const char* GLOBAL_MODULE_NAME = "GLOBAL";


// Returns it without trailing "::".
string extract_module_name(const char* name)
	{
	string module_name = name;
	string::size_type pos = module_name.rfind("::");

	if ( pos == string::npos )
		return string(GLOBAL_MODULE_NAME);

	module_name.erase(pos);

	return module_name;
	}

string normalized_module_name(const char* module_name)
	{
	int mod_len;
	if ( (mod_len = strlen(module_name)) >= 2 &&
	     ! strcmp(module_name + mod_len - 2, "::") )
		mod_len -= 2;

	return string(module_name, mod_len);
	}

string make_full_var_name(const char* module_name, const char* var_name)
	{
	if ( ! module_name || streq(module_name, GLOBAL_MODULE_NAME) ||
	     strstr(var_name, "::") )
		return string(var_name);

	string full_name = normalized_module_name(module_name);
	full_name += "::";
	full_name += var_name;

	return full_name;
	}

Scope::Scope(ID* id)
	{
	scope_id = id;
	return_type = 0;

	local = new PDict(ID)(ORDERED);
	inits = new id_list;

	if ( id )
		{
		BroType* id_type = id->Type();

		if ( id_type->Tag() == TYPE_ERROR )
			return;
		else if ( id_type->Tag() != TYPE_FUNC )
			internal_error("bad scope id");

		Ref(id);

		FuncType* ft = id->Type()->AsFuncType();
		return_type = ft->YieldType();
		if ( return_type )
			Ref(return_type);
		}
	}

Scope::~Scope()
	{
	for ( int i = 0; i < local->Length(); ++i )
		Unref(local->NthEntry(i));

	Unref(scope_id);
	Unref(return_type);
	delete local;
	delete inits;
	}

ID* Scope::GenerateTemporary(const char* name)
	{
	return new ID(copy_string(name), SCOPE_FUNCTION, false);
	}

id_list* Scope::GetInits()
	{
	id_list* ids = inits;
	inits = 0;
	return ids;
	}

void Scope::Describe(ODesc* d) const
	{
	if ( d->IsReadable() )
		d->AddSP("scope");

	else
		{
		d->Add(scope_id != 0);
		d->SP();
		d->Add(return_type != 0);
		d->SP();
		d->Add(local->Length());
		d->SP();
		}

	if ( scope_id )
		{
		scope_id->Describe(d);
		d->NL();
		}

	if ( return_type )
		{
		return_type->Describe(d);
		d->NL();
		}

	for ( int i = 0; i < local->Length(); ++i )
		{
		ID* id = local->NthEntry(i);
		id->Describe(d);
		d->NL();
		}
	}

TraversalCode Scope::Traverse(TraversalCallback* cb) const
	{
	PDict(ID)* ids = GetIDs();
	IterCookie* iter = ids->InitForIteration();

	HashKey* key;
	ID* id;
	while ( (id = ids->NextEntry(key, iter)) )
		{
		TraversalCode tc = id->Traverse(cb);
		HANDLE_TC_STMT_PRE(tc);
		}

	return TC_CONTINUE;
	}


ID* lookup_ID(const char* name, const char* curr_module, bool no_global)
	{
	string fullname = make_full_var_name(curr_module, name);
	string ID_module = extract_module_name(fullname.c_str());
	bool need_export = ID_module != GLOBAL_MODULE_NAME &&
				ID_module != curr_module;

	for ( int i = scopes.length() - 1; i >= 0; --i )
		{
		ID* id = scopes[i]->Lookup(fullname.c_str());
		if ( id )
			{
			if ( need_export && ! id->IsExport() && ! in_debug )
				error("identifier is not exported:",
				      fullname.c_str());

			Ref(id);
			return id;
			}
		}

	if ( ! no_global )
		{
		string globalname = make_full_var_name(GLOBAL_MODULE_NAME, name);
		ID* id = global_scope()->Lookup(globalname.c_str());
		if ( id )
			{
			Ref(id);
			return id;
			}
		}

	return 0;
	}

ID* install_ID(const char* name, const char* module_name,
		bool is_global, bool is_export)
	{
	if ( scopes.length() == 0 && ! is_global )
		internal_error("local identifier in global scope");

	IDScope scope;
	if ( is_export || ! module_name ||
	     (is_global &&
	      normalized_module_name(module_name) == GLOBAL_MODULE_NAME) )
		scope = SCOPE_GLOBAL;
	else if ( is_global )
		scope = SCOPE_MODULE;
	else
		scope = SCOPE_FUNCTION;

	string full_name_str = make_full_var_name(module_name, name);
	char* full_name = copy_string(full_name_str.c_str());

	ID* id = new ID(full_name, scope, is_export);
	if ( SCOPE_FUNCTION != scope )
		global_scope()->Insert(full_name, id);
	else
		{
		id->SetOffset(top_scope->Length());
		top_scope->Insert(full_name, id);
		}

	return id;
	}

void push_existing_scope(Scope* scope)
	{
	scopes.append(scope);
	}

void push_scope(ID* id)
	{
	top_scope = new Scope(id);
	scopes.append(top_scope);
	}

Scope* pop_scope()
	{
	int n = scopes.length() - 1;
	if ( n < 0 )
		internal_error("scope underflow");
	scopes.remove_nth(n);

	Scope* old_top = top_scope;
	// Don't delete the scope; keep it around for later name resolution
	// in the debugger.
	// ### SERIOUS MEMORY LEAK!?
	// delete top_scope;

	top_scope = n == 0 ? 0 : scopes[n-1];

	return old_top;
	}

Scope* current_scope()
	{
	return top_scope;
	}

Scope* global_scope()
	{
	return scopes[0];
	}
