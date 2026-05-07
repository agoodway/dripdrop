[
  # Ecto.Multi/Query opaque type warnings are standard dialyzer noise around Ecto macros.
  ~r/call_without_opaque/,
  # public_key certificate records are valid at runtime but underspecified for Dialyzer here.
  {"lib/dripdrop/channels/email/ses.ex", :call},
  {"lib/dripdrop/channels/email/ses.ex", :no_return}
]
