import type * as Preset from "@docusaurus/preset-classic";
import type { Config } from "@docusaurus/types";
import { PluginOptions } from "docusaurus-plugin-typedoc";
import { themes as prismThemes } from "prism-react-renderer";

// This runs in Node.js - Don't use client-side code here (browser APIs, JSX...)

const config: Config = {
  title: "Bangla Toolkit",
  tagline: "A comprehensive suite of tools for working with Bangla language",
  favicon: "img/logo.svg",

  // Set the production url of your site here
  url: "https://bangla-toolkit.github.io",
  // Set the /<baseUrl>/ pathname under which your site is served
  // For GitHub pages deployment, it is often '/<projectName>/'
  baseUrl: "/core/",

  // GitHub pages deployment config.
  // If you aren't using GitHub pages, you don't need these.
  organizationName: "bangla-toolkit", // Usually your GitHub org/user name.
  projectName: "core", // Usually your repo name.

  onBrokenLinks: "throw",
  onBrokenMarkdownLinks: "warn",

  // Even if you don't use internationalization, you can use this field to set
  // useful metadata like html lang. For example, if your site is Chinese, you
  // may want to replace "en" with "zh-Hans".
  i18n: {
    defaultLocale: "en",
    locales: ["en"],
  },
  themes: ["@docusaurus/theme-live-codeblock"],
  plugins: [
    [
      "docusaurus-plugin-typedoc",
      {
        entryPoints: ["../packages/core/*"],
        entryPointStrategy: "packages",
        tsconfig: "../tsconfig.json",
        plugin: ["typedoc-plugin-markdown", "typedoc-plugin-frontmatter"],
        readme: "none",
        // Markdown Options
        excludeScopesInPaths: true,
        mergeReadme: true,
        // hidePageHeader: true,
        // hideBreadcrumbs: true,
        //   "hidePageTitle": true,
        hideGroupHeadings: true,
        //   "excludeGroups": true,
        parametersFormat: "table",
        interfacePropertiesFormat: "table",
        classPropertiesFormat: "table",
        typeAliasPropertiesFormat: "table",
        enumMembersFormat: "table",
        propertyMembersFormat: "table",
        typeDeclarationFormat: "table",
        // flattenOutputFiles: true,
        typeDeclarationVisibility: "compact", // compact | verbose
        useCodeBlocks: true,
        // groupOrder: ["functions", "enumerations", "Interfaces", "Enums"],
        //   "sidebar": { "pretty": true },
        formatWithPrettier: true,
        prettierConfigFile: "../.prettierrc",
        // @ts-expect-error
        textContentMappings: {
          "title.indexPage": "API Reference",
          // "header.title": "API Reference",
          // "breadcrumbs.home": "API Reference",
          "title.memberPage": "{name}",
          "title.modulePage": "📦 {name}",
        },
        membersWithOwnFile: [],
      } satisfies PluginOptions,
    ],
  ],
  presets: [
    [
      "classic",
      {
        docs: {
          sidebarPath: "./sidebars.ts",
          // Please change this to your repo.
          // Remove this to remove the "edit this page" links.
          // editUrl: "https://github.com/bangla-toolkit/bntk/tree/main/docs/",
          remarkPlugins: [
            [
              require("@docusaurus/remark-plugin-npm2yarn"),
              { sync: true, converters: ["bun", "yarn", "pnpm"] },
            ],
          ],
        },
        blog: {
          showReadingTime: true,
          feedOptions: {
            type: ["rss", "atom"],
            xslt: true,
          },
          // Please change this to your repo.
          // Remove this to remove the "edit this page" links.
          // editUrl: "https://github.com/bangla-toolkit/bntk/tree/main/docs/",
          // Useful options to enforce blogging best practices
          onInlineTags: "warn",
          onInlineAuthors: "warn",
          onUntruncatedBlogPosts: "warn",
        },
        theme: {
          customCss: "./src/css/custom.css",
        },
      } satisfies Preset.Options,
    ],
  ],
  themeConfig: {
    // Replace with your project's social card
    colorMode: {
      disableSwitch: true,
      respectPrefersColorScheme: true,
    },
    image: "img/logo.svg",
    navbar: {
      title: "Bangla Toolkit",
      logo: {
        alt: "Bangla Toolkit Logo",
        src: "img/logo.svg",
        srcDark: "img/logo.svg",
      },
      items: [
        {
          type: "docSidebar",
          sidebarId: "tutorialSidebar",
          position: "left",
          label: "Docs",
        },
        {
          href: "https://bangla-toolkit.github.io/web/",
          label: "Try Online",
          position: "left",
        },
        // { to: "/blog", label: "Blog", position: "left" },
        {
          href: "https://github.com/bangla-toolkit",
          label: "GitHub",
          position: "right",
          className: "header-github-link",
        },
      ],
    },
    footer: {
      style: "dark",
      links: [
        {
          title: "Documentation",
          items: [
            {
              label: "Introduction",
              to: "/docs/intro",
            },
            {
              label: "Getting Started",
              to: "/docs/getting-started",
            },
            {
              label: "API Reference",
              to: "/docs/api",
            },
          ],
        },
        {
          title: "Community",
          items: [
            {
              label: "GitHub Discussions",
              href: "https://github.com/bangla-toolkit/bntk/discussions",
            },
            {
              label: "X (Twitter)",
              href: "https://x.com/bangla_toolkit",
            },
          ],
        },
        {
          title: "More",
          items: [
            // {
            //   label: "Blog",
            //   to: "/blog",
            // },
            {
              label: "GitHub",
              href: "https://github.com/bangla-toolkit",
            },
          ],
        },
      ],
      copyright: `Copyright © ${new Date().getFullYear()} Bangla Toolkit.`,
    },
    prism: {
      theme: prismThemes.github,
      darkTheme: prismThemes.dracula,
    },
  } satisfies Preset.ThemeConfig,
};

export default config;
