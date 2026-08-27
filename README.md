# irssi-ai-bot

An Irssi script that lets AI multi-character personalities chat in your IRC
channels. Bots are defined in a JSON config and each can use a different LLM
endpoint (OpenRouter, Google Gemini, local Ollama, or any OpenAI-compatible
server). It is fully non-blocking: API calls run in a child process so Irssi
never freezes while waiting for a response.

## Features

- Multiple AI personalities, one per config entry, each with its own model,
  endpoint, system prompt, temperature and token limit.
- Non-blocking design: each request is forked into a child process and read
  back through a pipe, so Irssi stays responsive.
- Per-channel, per-bot memory that is persisted to disk and reloaded on start.
- Chat history is trimmed per bot using `max_history`.
- Automatic retry with progress messages if an endpoint is slow.
- `!mcpchat confreload` reloads the bot config without restarting Irssi.
- Optional per-bot tool calling (sent through when present in the config).

## Requirements

- Irssi
- Perl modules: `LWP::UserAgent`, `HTTP::Request::Common`, `JSON`, `IO::Handle`,
  `POSIX`, `File::Spec` (these usually ship with Irssi/your distro).

## Installation

```sh
mkdir -p ~/.irssi/scripts
cp irssi-ai-bot.pl ~/.irssi/scripts/
cp irssi-ai-bot.config.json ~/.irssi/scripts/

# In Irssi:
/script load irssi-ai-bot
```

To autoload it on startup, copy the script into `~/.irssi/scripts/autorun/`
or add `/script load irssi-ai-bot` to your irssi startup file.

## Configuration

Edit `~/.irssi/scripts/irssi-ai-bot.config.json`. It is a JSON array of bot
objects. The shipped file contains three commented-out examples that are
disabled by default via `"enabled": false`:

| Persona         | Provider                      |
|-----------------|-------------------------------|
| cowboy          | OpenRouter                    |
| duke (Duke Nukem-style) | Google Gemini        |
| akshually (pedantic nerd) | local LLM endpoint |

Each bot supports these keys:

- `name` - what people type to address the bot (e.g. `cowboy: hello`).
- `enabled` - set to `true` to make the bot active.
- `api_key` - your API key; leave empty for local endpoints that need none.
- `model` - the model name to request.
- `endpoint` - the chat completions endpoint (defaults to OpenRouter).
- `system_prompt` - the personality/instructions for the bot.
- `max_tokens` - maximum tokens in a response.
- `temperature` - sampling temperature.
- `max_history` - how many prior messages to keep in memory.
- `tools` - optional array of tools to send to the API.

To activate an example, set `"enabled": true` and fill in `api_key` (and adjust
`model`/`endpoint` as needed for your provider).

## Usage

Address a bot in a channel by writing its name followed by a space, comma,
colon, semicolon, exclamation or question mark:

```
[channel] cowboy: howdy partner
[channel] duke: come get some
[channel] akshually: actually the moon is not made of cheese
```

To re-read the config file at runtime:

```
!mcpchat confreload
```

## How it works

1. On load, the script reads the JSON config to build the list of active bots.
2. When a public message addresses a bot, the script builds a chat array from
   the bot's system prompt, the relevant channel history, and the message.
3. The request payload is sent to the endpoint from a forked child process; the
   parent reads the reply through a pipe without blocking Irssi.
4. Successful replies are sent to the channel and appended to the on-disk
   history for that channel/bot.

## Compatibility

The script is intended for Irssi. Because the API call is forked into a child
process, it works with any OpenAI-compatible chat completions endpoint,
including OpenRouter, Google Gemini's OpenAI-compatible surface, and local
servers such as Ollama or llama.cpp.

## License

MIT. See [LICENSE](LICENSE).
