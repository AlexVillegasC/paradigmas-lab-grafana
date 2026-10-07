# Infrastructure

Docker Compose project for `LibrariesApiTest` and `LibrariesFE`.

Settings live in this folder so a GitHub Actions repo can load them by startup configuration. `.env.local` and `.env.development` are gitignored; copy the `*.example` files and put real connection strings only in the untracked copies.

| File | Stack |
| --- | --- |
| `.env.local` | API + frontend + a local Postgres container |
| `.env.development` | API + frontend using a Supabase Postgres connection string |

The same variable names are also present in each app repo (`.env.local` / `.env.development` and their `.example` copies) for `dotnet run` / `npm run dev` outside Compose.

## Start

From this folder:

```powershell
.\start.ps1 local
.\start.ps1 development
```

Or:

```bash
docker compose --env-file .env.local --profile local up --build
docker compose --env-file .env.development up --build
```

- Frontend: http://localhost:5173
- API / Swagger: http://localhost:8080/swagger
- Local Postgres: `localhost:5432` (`library` / `library` / `librarydb`)

## Development (Supabase)

1. Copy `.env.development.example` to `.env.development` (gitignored).
2. Set `CONNECTION_STRING` to the Supabase Postgres connection string (keyword format):

```text
Host=db.<project>.supabase.co;Port=5432;Database=postgres;Username=postgres;Password=<password>;SSL Mode=Require;Trust Server Certificate=true
```

3. Start with `.env.development`. The `postgres` service is not created.

## GitHub Actions

A pipeline in this repo can select the file by environment:

```yaml
docker compose --env-file .env.${{ inputs.environment }} ${{ inputs.environment == 'local' && '--profile local' || '' }} up -d --build
```

Checkout this repo and the two app repos as siblings (`LibrariesApiTest`, `LibrariesFE`) so the default `API_CONTEXT` / `FE_CONTEXT` paths resolve. Override those variables, or `API_IMAGE` / `FE_IMAGE`, if the pipeline builds images elsewhere.

Put the real Supabase connection string in a GitHub secret named `CONNECTION_STRING` and export it before Compose so it overrides the placeholder in `.env.development`. Escape any `$` in that string as `$$` so Compose does not treat it as interpolation.

## App env files

| Location | Used when |
| --- | --- |
| `infrastructure/.env.local` | Compose local profile |
| `infrastructure/.env.development` | Compose development (Supabase) |
| `LibrariesApiTest/.env.local` | `dotnet run` against host-mapped local Postgres |
| `LibrariesApiTest/.env.development` | `dotnet run` against Supabase |
| `LibrariesFE/.env.docker` | Vite inside the frontend container |
| `LibrariesFE/.env.development` | Host `npm run dev` (Vite mode), not the Compose development file |
