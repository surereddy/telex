// $Id: RSH.cc 6219 2008-10-01 05:39:07Z vern $

// See the file "COPYING" in the main distribution directory for copyright.

#include "config.h"

#include "NetVar.h"
#include "Event.h"
#include "RSH.h"


// FIXME: this code should probably be merged with Rlogin.cc.

Contents_Rsh_Analyzer::Contents_Rsh_Analyzer(Connection* conn, bool orig,
						Rsh_Analyzer* arg_analyzer)
: ContentLine_Analyzer(AnalyzerTag::Contents_Rsh, conn, orig)
	{
	num_bytes_to_scan = num_bytes_to_scan = 0;
	analyzer = arg_analyzer;

	if ( orig )
		state = save_state = RSH_FIRST_NULL;
	else
		state = RSH_LINE_MODE;
	}

Contents_Rsh_Analyzer::~Contents_Rsh_Analyzer()
	{
	}

void Contents_Rsh_Analyzer::DoDeliver(int len, const u_char* data)
	{
	TCP_Analyzer* tcp = static_cast<TCP_ApplicationAnalyzer*>(Parent())->TCP();
	assert(tcp);

	int endp_state = IsOrig() ? tcp->OrigState() : tcp->RespState();

	for ( ; len > 0; --len, ++data )
		{
		if ( offset >= buf_len )
			InitBuffer(buf_len * 2);

		unsigned int c = data[0];

		switch ( state ) {
		case RSH_FIRST_NULL:
			if ( endp_state == TCP_ENDPOINT_PARTIAL ||
			     // We can be in closed if the data's due to
			     // a dataful FIN being the first thing we see.
			     endp_state == TCP_ENDPOINT_CLOSED )
				{
				state = RSH_UNKNOWN;
				++len, --data;	// put back c and reprocess
				continue;
				}

			if ( c >= '0' && c <= '9' )
				; // skip stderr port number
			else if ( c == '\0' )
				state = RSH_CLIENT_USER_NAME;
			else
				BadProlog();

			break;

		case RSH_CLIENT_USER_NAME:
		case RSH_SERVER_USER_NAME:
			buf[offset++] = c;
			if ( c == '\0' )
				{
				if ( state == RSH_CLIENT_USER_NAME )
					{
					analyzer->ClientUserName((const char*) buf);
					state = RSH_SERVER_USER_NAME;
					}

				else if ( state == RSH_SERVER_USER_NAME &&
					  offset > 1 )
					{
					analyzer->ServerUserName((const char*) buf);
					save_state = state;
					state = RSH_LINE_MODE;
					}

				offset = 0;
				}
			break;

		case RSH_LINE_MODE:
		case RSH_UNKNOWN:
		case RSH_PRESUMED_REJECTED:
			if ( state == RSH_LINE_MODE &&
			     state == RSH_PRESUMED_REJECTED )
				{
				Conn()->Weird("rsh_text_after_rejected");
				state = RSH_UNKNOWN;
				}

			if ( c == '\n' || c == '\r' )
				{ // CR or LF (RFC 1282)
				if ( c == '\n' && last_char == '\r' )
					// Compress CRLF to just 1 termination.
					;
				else
					{
					buf[offset] = '\0';
					ForwardStream(offset, buf, IsOrig()); \
					save_state = RSH_LINE_MODE;
					offset = 0;
					break;
					}
				}

			if ( c == '\0' )
				{
				buf[offset] = '\0';
				ForwardStream(offset, buf, IsOrig()); \
				save_state = RSH_LINE_MODE;
				offset = 0;
				break;
				}

			else
				buf[offset++] = c;

			last_char = c;
			break;

		default:
			internal_error("bad state in Contents_Rsh_Analyzer::DoDeliver");
			break;
		}
		}
	}

void Contents_Rsh_Analyzer::BadProlog()
	{
	Conn()->Weird("bad_rsh_prolog");
	state = RSH_UNKNOWN;
	}

Rsh_Analyzer::Rsh_Analyzer(Connection* conn)
: Login_Analyzer(AnalyzerTag::Rsh, conn)
	{
	contents_orig = new Contents_Rsh_Analyzer(conn, true, this);
	contents_resp = new Contents_Rsh_Analyzer(conn, false, this);
	AddSupportAnalyzer(contents_orig);
	AddSupportAnalyzer(contents_resp);
	}

void Rsh_Analyzer::DeliverStream(int len, const u_char* data, bool orig)
	{
	Login_Analyzer::DeliverStream(len, data, orig);

	const char* line = (const char*) data;
	val_list* vl = new val_list;

	line = skip_whitespace(line);
	vl->append(BuildConnVal());
	vl->append(client_name ? client_name->Ref() : new StringVal("<none>"));
	vl->append(username ? username->Ref() : new StringVal("<none>"));
	vl->append(new StringVal(line));

	if ( orig && rsh_request )
		{
		if ( contents_orig->RshSaveState() == RSH_SERVER_USER_NAME )
			// First input
			vl->append(new Val(true, TYPE_BOOL));
		else
			vl->append(new Val(false, TYPE_BOOL));

		ConnectionEvent(rsh_request, vl);
		}

	else if ( rsh_reply )
		ConnectionEvent(rsh_reply, vl);
	}

void Rsh_Analyzer::ClientUserName(const char* s)
	{
	if ( client_name )
		internal_error("multiple rsh client names");

	client_name = new StringVal(s);
	}

void Rsh_Analyzer::ServerUserName(const char* s)
	{
	if ( username )
		internal_error("multiple rsh initial client names");

	username = new StringVal(s);
	}
