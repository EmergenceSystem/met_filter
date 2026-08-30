# met_filter

A source filter for **[EmergenceSystem](https://github.com/EmergenceSystem)**, a distributed
discovery network of small agents. It joins the em_pop gossip mesh and answers
`POST /agent/query`: it searches the Metropolitan Museum of Art open-access collection (collectionapi.metmuseum.org), returned as media embryos
(thumbnail, title, source url) that render as image cards in the Emquest UI.

Emquest fans each query out to many such filters in parallel and aggregates the results,
so every filter stays small and focused on a single source. Keyless.

## Run

```sh
rebar3 shell
```

Built on [em_filter](https://github.com/EmergenceSystem/em_filter). Apache-2.0.
