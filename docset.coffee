Rx = require 'rx'
Fe = require 'fs-extra'
M  = require 'marked'
G  = require 'glob'
P  = require 'path'
F  = require 'fs'
C  = require 'cheerio'
S  = require 'sequelize'
T  = require './template'

NAME = 'rxjs.docset'

GITHUB_DOC_PATH = 'https://github.com/Reactive-Extensions/RxJS/tree/master/doc/'

RXJS_PATH = P.join __dirname, '.rxjs'
DOC_PATH  = P.join RXJS_PATH, 'doc'
DOC_GLOB  = P.join DOC_PATH, '**', '*.md'

DOCSET_PATH = P.join __dirname, NAME
DOCSET_RES  = P.join DOCSET_PATH, 'Contents', 'Resources'
DOCSET_DOC  = P.join DOCSET_RES , 'Documents'

Fe.copySync 'resources', NAME

db = new S 'database', 'username', 'password',
  dialect: 'sqlite'
  logging: no
  storage: P.join DOCSET_RES, 'docSet.dsidx'

searchIndex = db.define 'searchIndex',
  id:
    type: S.INTEGER
    autoIncrement: true
    primaryKey: true
  name: S.STRING
  type: S.STRING
  path: S.STRING
,
  freezeTableName: true
  timestamps: false

M.setOptions sanitize: false, gmf: true

readFile = (path) ->
  p   = path.replace "#{DOC_PATH}/", ''
  dir = P.dirname p
    .split P.sep
    .filter((x) -> !!x)[0] || ''

  # file_obj
  path: p
  dest: ''
  file_path: path
  relative_path: ''
  type: type dir
  name: ''
  dir: dir
  header: ''
  footer: ''
  marked: ''
  content: F.readFileSync(path).toString()

updateHeader = (file_obj) ->
  header   = file_obj.header
  rel_path = file_obj.relative_path
  header.replace /href="([^"]*)"/g, (match, p1) ->
    "href=\"#{P.join rel_path, p1}\""

updateLink = (file_obj) ->
  marked   = file_obj.marked
  rel_path = file_obj.relative_path
  marked.replace /<a[^>]* href="([^"]*)"/g, (match, p1) ->
    unless /(^http|https)/.test match
      match.replace /md"$/g, 'html"'
    else
      if ///#{GITHUB_DOC_PATH}///.test p1
        link = p1
          .replace ///#{GITHUB_DOC_PATH}///, ''
          .replace /md$/g, 'html'
        "<a href=\"#{P.join rel_path, link}\""
      else
        match

type = (dir) ->
  switch dir
    when 'libraries' then 'Library'
    when 'api' then 'Function'
    else 'Guide'

file_source = Rx.Observable.fromNodeCallback(G)(DOC_GLOB)
  .flatMap (files) -> Rx.Observable.fromArray files
  .map readFile
  .filter (file_obj) -> !!file_obj.content
  .map (file_obj) ->
    # add converted html
    file_obj.header = T.header
    file_obj.footer = T.footer
    file_obj.marked = M file_obj.content
    file_obj
  .map (file_obj) ->
    # update css path
    file_obj.relative_path = P.relative P.dirname(file_obj.file_path), DOC_PATH
    file_obj.header = updateHeader file_obj
    file_obj
  .map (file_obj) ->
    # fix internal links
    file_obj.marked = updateLink file_obj
    file_obj
  .map (file_obj) ->
    # update destination path
    dest = P.join DOCSET_DOC, file_obj.file_path.replace DOC_PATH, ''
    file_obj.dest = dest.replace /md$/g, 'html'
    file_obj

# write to html file
file_source
  .flatMap (file_obj) ->
    marked = "#{file_obj.header}#{file_obj.marked}#{file_obj.footer}"
    Rx.Observable.fromNodeCallback(Fe.outputFile)(file_obj.dest, marked)
      .map (err) ->
        if err
          throw "outputFile Error with file : #{file_obj.dest}"
        else
          true
  .every (x) -> x is yes
  .subscribe (result) -> console.log 'doc generated' if result

col_source = file_source
  .map (file_obj) ->
    $ = C.load file_obj.marked
    file_obj.name = if file_obj.type is 'Function'
      $('code').first().text().replace /\(.*\)/g, ''
    else
      $('h1').text()
    file_obj
  .map (file_obj) ->
    path: file_obj.path.replace /md$/g, 'html'
    type: file_obj.type
    name: file_obj.name
  .toArray()

# create db
Rx.Observable.fromPromise db.sync force: true
  .combineLatest col_source, (db, col) ->
    Rx.Observable.fromArray col
      .map (x) -> searchIndex.create x
  .concatAll()
  .subscribe (() ->)
  , ((err) ->)
  , () -> console.log 'db updated'

# copy css dependencies
Rx.Observable.fromArray [
  'bower_components/primer-css/css/primer.css',
  'bower_components/primer-markdown/dist/user-content.css'
]
  .flatMap (path) ->
    dest = P.join DOCSET_DOC, P.parse(path).base
    Rx.Observable.fromNodeCallback(Fe.copy)(path, dest)
      .map (err) ->
        if err
          throw "outputFile Error with file : #{file_obj.dest}"
        else
          true
  .every (x) -> x is yes
  .subscribe (result) -> console.log 'dep copied' if result
