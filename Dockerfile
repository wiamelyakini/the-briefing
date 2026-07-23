FROM node:alpine

WORKDIR /app

COPY package.json package-lock.json ./

RUN npm install

# Copy only source files — avoids recursive COPY of root context
COPY public/ ./public/
COPY src/ ./src/

# Run as non-root user to reduce blast radius of any compromise
RUN addgroup -S appgroup && adduser -S appuser -G appgroup
USER appuser

EXPOSE 3000

CMD ["npm", "start"]
