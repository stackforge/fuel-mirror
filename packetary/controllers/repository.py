# -*- coding: utf-8 -*-

#    Copyright 2015 Mirantis, Inc.
#
#    Licensed under the Apache License, Version 2.0 (the "License"); you may
#    not use this file except in compliance with the License. You may obtain
#    a copy of the License at
#
#         http://www.apache.org/licenses/LICENSE-2.0
#
#    Unless required by applicable law or agreed to in writing, software
#    distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
#    WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
#    License for the specific language governing permissions and limitations
#    under the License.

import functools
import logging
import os

import six
import stevedore


logger = logging.getLogger(__package__)

urljoin = six.moves.urllib.parse.urljoin


class RepositoryController(object):
    """Implements low-level functionality to communicate with drivers."""

    _drivers = None

    def __init__(self, context, driver, arch):
        self.context = context
        self.driver = driver
        self.arch = arch

    @classmethod
    def load(cls, context, driver_name, arch):
        """Creates the repository manager.

        :param context: the context
        :param driver_name: the name of required driver
        :param arch: the architecture of repository (x86_64 or i386)
        """
        if cls._drivers is None:
            cls._drivers = stevedore.ExtensionManager(
                "packetary.drivers", invoke_on_load=True
            )
        try:
            driver = cls._drivers[driver_name].obj
        except KeyError:
            raise NotImplementedError(
                "The driver {0} is not supported yet.".format(driver_name)
            )
        return cls(context, driver, arch)

    def load_repositories(self, urls, consumer):
        """Loads the repository objects from url.

        :param urls: the list of repository urls.
        :param consumer: the callback to consume objects
        """
        if isinstance(urls, six.string_types):
            urls = [urls]

        connection = self.context.connection
        for parsed_url in self.driver.parse_urls(urls):
            self.driver.get_repository(
                connection, parsed_url, self.arch, consumer
            )

    def load_packages(self, repositories, consumer):
        """Loads packages from repository.

        :param repositories: the repository object
        :param consumer: the callback to consume objects
        """
        connection = self.context.connection
        for r in repositories:
            self.driver.get_packages(connection, r, consumer)

    def assign_packages(self, repository, packages, keep_existing=True):
        """Assigns set of packages to the repository.

        :param repository: the target repository
        :param packages: the set of packages
        :param keep_existing:
        """

        if not isinstance(packages, set):
            packages = set(packages)
        else:
            packages = packages.copy()

        if keep_existing:
            consume_exist = packages.add
        else:
            consume_exist = functools.partial(
                remove_if_not, packages.__contains__
            )

        self.driver.get_packages(
            self.context.connection, repository, consume_exist
        )
        self.driver.rebuild_repository(repository, packages)

    def copy_packages(self, repository, packages, keep_existing, observer):
        """Copies packages to repository.

        :param repository: the target repository
        :param packages: the set of packages
        :param keep_existing: see assign_packages for more details
        :param observer: the package copying process observer
        """
        with self.context.async_section() as section:
            for package in packages:
                section.execute(
                    self._copy_package, repository, package, observer
                )
        self.assign_packages(repository, packages, keep_existing)

    def clone_repositories(self, repositories, destination,
                           source=False, locale=False):
        """Creates copy of repositories.

        :param repositories: the origin repositories
        :param destination: the target folder
        :param source: If True, the source packages will be copied too.
        :param locale: If True, the localisation will be copied too.
        :return: the mapping origin to cloned repository.
        """
        mirros = dict()
        destination = os.path.abspath(destination)
        with self.context.async_section(0) as section:
            for r in repositories:
                section.execute(
                    self._clone_repository,
                    r, destination, source, locale, mirros
                )
        return mirros

    def _clone_repository(self, r, destination, source, locale, mirrors):
        """Creates clone of repository and stores it in mirrors."""
        clone = self.driver.clone_repository(
            self.context.connection, r, destination, source, locale
        )
        mirrors[r] = clone

    def _copy_package(self, target, package, observer):
        """Synchronises remote file to local fs."""
        dst_path = os.path.join(target.url, package.filename)
        src_path = urljoin(package.repository.url, package.filename)
        bytes_copied = self.context.connection.retrieve(
            src_path, dst_path, size=package.filesize
        )
        if package.filesize < 0:
            package.filesize = bytes_copied
        observer(bytes_copied)


def remove_if_not(condition, package):
    """Removes package file if not condition.

    :param condition: function, that returns True of False.
    :param package: the package object
    """
    if not condition(package):
        filepath = os.path.join(package.repository.url, package.filename)
        logger.info("remove package - %s.", filepath)
        os.remove(filepath)
