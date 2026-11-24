FROM oven/bun:1.4.4@sha256:1d22548f177f4ff38e0c15baa3c2c46c6c2060ba2d1bc573bb4720b407548f1d
WORKDIR /app
COPY package.json ./
COPY src ./src
USER bun
EXPOSE 7355
CMD ["bun", "src/index.ts"]
