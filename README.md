[&larr; Go to main repository](https://github.com/lukevella/rallly)

# Hosting your own instance of Rallly

The best way to run Rallly on your own server is using the public image published on docker hub. This repo contains an example configuration that allows you to get your own instance of Rallly running in just a few simple steps.

## Requirements

You will need:

- Docker
- Access to an SMTP server for sending emails

## Setup

### Copy this project

Copy the contents of this repo on to your server or clone this repo with git:

```
git clone https://github.com/rallly/self-hosting.git
```

Feel free to name the contents of this folder to whatever your prefer.

### Configure the environment variables

In the root of this project you will find a file called `config.env`. Open this file with a text editor and:

- Set `SECRET_PASSWORD` - This should be a randomly generated string that will be used to encrypt user sessions. **It should be at least 32 characters long**.

- Set `NEXT_PUBLIC_BASE_URL` - This is the URL you will type in your browser to access your instance (eg. `https://rallly.example.com`). To be able to access the site using your own domain you will want to use a [reverse proxy](/reverse-proxy/).

- Set `SUPPORT_EMAIL` - This will appear as the support email in emails sent out by your instance.

- Configure `SMTP_HOST`, `SMTP_PORT`, `SMTP_USER` and `SMTP_PWD` with the details of your SMTP server.

### Start the server

You can start the server by running:

```
docker compose up -d
```

This command will:

- Create a postgres database
- Run migrations to set up the database schema
- Start the Next.js server on port 3000

## Updating your instance

Rallly is constantly being updated but you will need to manually pull these updates and restart the server to run the latest version. You can do this by running the following commands from within this directory:

```
docker compose down
docker compose pull
docker compose up -d
```
