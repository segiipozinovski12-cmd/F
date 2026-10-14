FROM node:24-bookworm-slim
WORKDIR /app
RUN npm install --global --ignore-scripts pnpm@11.25.0
COPY package.json pnpm-lock.yaml ./
RUN pnpm install --prod --frozen-lockfile --ignore-scripts
COPY src ./src
USER node
ENV VO1D_BOT_PASSWORD_FILE=/run/secrets/bot-password
ENTRYPOINT ["node", "src/cli.mjs"]
CMD ["--vault", "/state/bot.vo1dbot"]
