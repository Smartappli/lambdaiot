FROM ubuntu:18.04

# Set version and github repo which you want to build from
ENV GITHUB_OWNER apache
ENV DRUID_VERSION 0.12.2
ENV ZOOKEEPER_VERSION 3.4.10
ARG DEBIAN_FRONTEND=noninteractive
ENV LANG=fr_BE.UTF-8 \
TZ=Europe/Brussels

# Java 8
RUN apt-get update \
      && apt-get install -y software-properties-common debconf \
      && apt-add-repository -y ppa:webupd8team/java \
      && apt-get purge --auto-remove -y \
      && apt-get update \
      && echo oracle-java-8-installer shared/accepted-oracle-license-v1-1 select true | /usr/bin/debconf-set-selections \
      && apt-get install -y oracle-java8-installer oracle-java8-set-default \
                            apt-utils \
                            postgresql-10 \
			    redis-server \
			    sudo \
                            supervisor \
                            git \
      && apt-get clean \
      && rm -rf /var/cache/oracle-jdk8-installer \
      && rm -rf /var/lib/apt/lists/*

RUN echo 'tzdata tzdata/Areas select Europe' | debconf-set-selections \ 
	&& echo 'tzdata tzdata/Zones/Europe select Brussels' | debconf-set-selections \ 
	&& echo 'debconf debconf/frontend select Noninteractive' | debconf-set-selections \
  	&& apt-get -y install wget tzdata locales \
  	&& locale-gen $LANG \
  	&& export LANG=fr_BE.UTF-8 \
  	&& dpkg-reconfigure -f noninteractive locales \
  	&& echo ${TZ} > /etc/timezone \
  	&& dpkg-reconfigure -f noninteractive tzdata \
  	&& echo "Contents of /etc/timezone and /etc/default/locale :" \
	&& cat /etc/timezone && cat /etc/default/locale 

# Maven
RUN wget -q -O - http://archive.apache.org/dist/maven/maven-3/3.2.5/binaries/apache-maven-3.2.5-bin.tar.gz | tar -xzf - -C /usr/local \
      && ln -s /usr/local/apache-maven-3.2.5 /usr/local/apache-maven \
      && ln -s /usr/local/apache-maven/bin/mvn /usr/local/bin/mvn

# Zookeeper
RUN wget -q -O - http://www.us.apache.org/dist/zookeeper/zookeeper-$ZOOKEEPER_VERSION/zookeeper-$ZOOKEEPER_VERSION.tar.gz | tar -xzf - -C /usr/local \
      && cp /usr/local/zookeeper-$ZOOKEEPER_VERSION/conf/zoo_sample.cfg /usr/local/zookeeper-$ZOOKEEPER_VERSION/conf/zoo.cfg \
      && ln -s /usr/local/zookeeper-$ZOOKEEPER_VERSION /usr/local/zookeeper

# Druid system user
RUN adduser --system --group --no-create-home druid \
      && mkdir -p /var/lib/druid \
      && chown druid:druid /var/lib/druid

# Druid (from source)
RUN mkdir -p /usr/local/druid/lib

# trigger rebuild only if branch changed
ADD https://api.github.com/repos/$GITHUB_OWNER/incubator-druid/git/refs/heads/$DRUID_VERSION druid-version.json
RUN git clone -q --branch $DRUID_VERSION --depth 1 https://github.com/$GITHUB_OWNER/incubator-druid.git /tmp/druid
WORKDIR /tmp/druid

# package and install Druid locally
# use versions-maven-plugin 2.1 to work around https://jira.codehaus.org/browse/MVERSIONS-285
RUN mvn -U -B org.codehaus.mojo:versions-maven-plugin:2.1:set -DgenerateBackupPoms=false -DnewVersion=$DRUID_VERSION \
  && mvn -U -B install -DskipTests=true -Dmaven.javadoc.skip=true \
  && cp services/target/druid-services-$DRUID_VERSION-selfcontained.jar /usr/local/druid/lib \
  && cp -r distribution/target/extensions /usr/local/druid/ \
  && cp -r distribution/target/hadoop-dependencies /usr/local/druid/ \
  && apt-get purge --auto-remove -y git \
  && apt-get clean \
  && rm -rf /tmp/* \
            /var/tmp/* \
            /usr/local/apache-maven-3.2.5 \
            /usr/local/apache-maven \
            /root/.m2

WORKDIR /

# Setup metadata store and add sample data
#ADD sample-data.sql sample-data.sql
RUN service postgresql start \
       && sudo -u postgres bash -c "psql -c \"CREATE USER druid WITH PASSWORD 'diurd';\"" \
       && sudo -u postgres createdb druid -O druid \
       && sudo -u postgres bash -c "psql -c \"GRANT ALL PRIVILEGES ON DATABASE druid TO druid;\"" \
       && java -cp /usr/local/druid/lib/druid-services-*-selfcontained.jar \
           -Ddruid.extensions.directory=/usr/local/druid/extensions \
           -Ddruid.extensions.loadLIst=[\"druid-histogram\",\"druid-datasketches\",\"druid-hdfs-storage\",\"postgresql-metadata-storage\",\"druid-redis-cache\",\"druid-kafka-indexing-service\",\"druid-stats\"] \
	   -Ddruid.storage.type=hdfs \
	   -Ddruid.cache.type=redis \
	   -Ddruid.cache.host=localhost \
	   -Ddruid.cache.port=6379 \
	   -Ddruid.indexer.logs.type=hdfs \
	   -Ddruid.indexer.logs.directory=/usr/local/druid/indexing-logs \
	   -Ddruid.storage.storageDirectory=/usr/local/druid/segments \
           -Ddruid.metadata.storage.type=postgresql \
           io.druid.cli.Main tools \
# metadata-init \
#               --connectURI="jdbc:postgresql://localhost:5432/druid" \
#               --user=druid --password=diurd \
# && mysql -u root druid < sample-data.sql \
      && service postgresql stop

# Setup Redis 
RUN wget -q -O - https://github.com/antirez/redis/archive/4.0.10.tar.gz | tar -xzf - -C /usr/local \
  && cd /usr/local/redis-4.0.10 \
  && make V=1 \
  && make install 
  
# Setup kafka
RUN wget -q -O - http://apache.cu.be/kafka/1.1.0/kafka_2.11-1.1.0.tgz | tar -xvzf - -C /usr/local \
  && cd /usr/local/kafka_2.11-1.1.0 \
  && bin/zookeeper-server-start.sh config/zookeeper.properties \
  #&& cp config/server.properties config/server-1.properties \
  #&& cp config/server.properties config/server-2.properties \
  && bin/kafka-server-start.sh config/server.properties \
# Setup supervisord
ADD supervisord.conf /etc/supervisor/conf.d/supervisord.conf

# Expose ports:
# - 8081: HTTP (coordinator)
# - 8082: HTTP (broker)
# - 8083: HTTP (historical)
# - 8090: HTTP (overlord)
# - 6379: Redis
# - 5432: PostgreSQL
# - 2181 2888 3888: ZooKeeper
# - 9001: Supervisord UI
EXPOSE 8081
EXPOSE 8082
EXPOSE 8083
EXPOSE 8090
EXPOSE 6379
EXPOSE 5432
EXPOSE 2181 2888 3888
EXPOSE 9001

WORKDIR /var/lib/druid
ENTRYPOINT export HOSTIP="$(resolveip -s $HOSTNAME)" && exec /usr/bin/supervisord -c /etc/supervisor/conf.d/supervisord.conf
