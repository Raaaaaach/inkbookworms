FROM ruby:3.3-slim

WORKDIR /app

COPY Gemfile ./
RUN gem install bundler -v 2.5.23 && bundle install

COPY public ./public
COPY data ./data
COPY server.rb ./
COPY Procfile ./

ENV BIND=0.0.0.0
ENV PORT=10000
ENV DATA_DIR=/var/data
ENV RACK_ENV=production

RUN mkdir -p /var/data

EXPOSE 10000
CMD ["bundle", "exec", "ruby", "server.rb"]
